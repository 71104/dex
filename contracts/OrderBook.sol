// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice Represents an order.
/// @dev It's unspecified whether this is a buy or sell order because our `OrderBook` data structure
///   works for both and each market has two separate order books, one for buys and one for sells.
/// @dev Orders are identified by an incremental ID (the `id` field) that's unique per order book.
///   The lowest valid ID is 1 because 0 is used as a sentinel value.
struct Order {
  /// @notice The unique incremental identifier for this order within its order book.
  uint256 id;
  /// @notice The address of the account that issued this order.
  address issuer;
  /// @notice The number of units to buy or sell.
  uint256 units;
  /// @notice The limit price per unit.
  uint256 price;
}

/// @notice An order book for either buy or sell orders.
/// @dev At any given time each market has two order books: one for buy orders and one for sell
///   orders.
/// @dev `OrderBook` is implemented as a binary heap of `Order`s sorted by price. Sell orders are
///   sorted by lowest price first because buyers are interested in the lowest prices, while buy
///   orders are sorted by highest price first because sellers are interested in the highest prices.
///   Therefore, by using a max-heap for buyers and a min-heap for sellers we can achieve optimal
///   matching. The `maxHeap` flag indicates whether this is a max-heap.
/// @dev Two orders with the same price are ordered by lowest ID first, regardless of the heap type.
///   Since order IDs are incremental, ordering by lowest ID is equivalent to ordering
///   chronologically, so that if two orders have the same price the one that came first is
///   fulfilled first.
struct OrderBook {
  /// @notice If true this is a max-heap, otherwise it's a min-heap.
  bool maxHeap;
  /// @notice This counter generates incremental order IDs and keeps track of the last generated ID.
  ///   Note that ID 0 is conventionally invalid, so it's okay to initialize this field to 0 for an
  ///   empty order book because no order has that ID.
  uint256 lastOrderId;
  /// @notice The order array, managed as a binary heap.
  Order[] orders;
  /// @notice Maps order IDs to their respective indices within the order array.
  mapping(uint256 => uint256) orderIndexById;
  /// @notice Associates order issuers with the list of all their order IDs. Note that orders are
  ///   not cleaned up from this list upon fulfillment or cancellation, they're stored forever.
  mapping(address => uint256[]) orderIdsByIssuer;
  /// @notice The sum of all units of all currently tracked orders. Used to calculate the current
  ///   market price as a weighted average.
  uint256 unitSum;
  /// @notice The sum of all prices of all units of all orders, ie. `Sum(price[i] * units[i])`. Used
  ///   to calculate the current market price as a weighted average.
  uint256 priceSum;
}

/// @title OrderBookMethods
/// @notice Library providing heap-based order book operations for managing and matching limit
///   orders.
library OrderBookMethods {
  /// @notice Thrown when a function receives an invalid argument.
  error InvalidArgument();

  /// @notice Thrown when a function receives an invalid order ID.
  /// @param orderId The order ID that was not found.
  error InvalidOrderId(uint256 orderId);

  /// @notice Thrown when the caller attempts to cancel an order they did not issue.
  /// @param orderId The ID of the order the caller tried to cancel.
  /// @param originalIssuer The address that originally placed the order.
  /// @param canceler The address that attempted to cancel the order.
  error PermissionDenied(uint256 orderId, address originalIssuer, address canceler);

  /// @notice Initializes an `OrderBook`.
  /// @dev The `OrderBook` is required to be in a zero state before calling this method.
  /// @param orderBook The `OrderBook` instance.
  /// @param sell True if this is for sell orders.
  function initialize(OrderBook storage orderBook, bool sell) external {
    orderBook.maxHeap = !sell;
  }

  /// @notice Returns the number of orders currently in the book.
  /// @param orderBook The `OrderBook` instance.
  /// @return The number of orders in this book.
  function length(OrderBook storage orderBook) external view returns (uint256) {
    return orderBook.orders.length;
  }

  /// @notice Returns the index of the parent of the element at `index`.
  /// @param index The index of the child element. Must be greater than 0 because the element at
  ///   slot 0 is the root and has no parent.
  /// @return The index of the parent element.
  function parentOf(uint256 index) private pure returns (uint256) {
    assert(index > 0);
    return (index - 1) / 2;
  }

  /// @notice Returns the index of the left child of the element at `index`.
  /// @param index The index of the parent element.
  /// @return The index of the left child element.
  function leftChildOf(uint256 index) private pure returns (uint256) {
    return index * 2 + 1;
  }

  /// @notice Returns the index of the right child of the element at `index`.
  /// @param index The index of the parent element.
  /// @return The index of the right child element.
  function rightChildOf(uint256 index) private pure returns (uint256) {
    return index * 2 + 2;
  }

  /// @notice Compares two orders based on the heap order and returns true iff the LHS is more
  ///   extreme than the RHS.
  /// @param orderBook The `OrderBook` instance, used to determine heap direction.
  /// @param lhsIndex Index of the left hand side of the comparison.
  /// @param rhsIndex Index of the right hand side of the comparison.
  /// @return True iff the LHS is more extreme than the RHS based on the heap order.
  function compareOrders(
    OrderBook storage orderBook,
    uint256 lhsIndex,
    uint256 rhsIndex
  ) private view returns (bool) {
    Order storage lhs = orderBook.orders[lhsIndex];
    Order storage rhs = orderBook.orders[rhsIndex];
    if (orderBook.maxHeap) {
      return lhs.price > rhs.price || (lhs.price == rhs.price && lhs.id < rhs.id);
    } else {
      return lhs.price < rhs.price || (lhs.price == rhs.price && lhs.id < rhs.id);
    }
  }

  /// @notice Swaps two elements in the heap.
  /// @param orderBook The `OrderBook` instance.
  /// @param index1 The first element index.
  /// @param index2 The second element index.
  function swap(OrderBook storage orderBook, uint256 index1, uint256 index2) private {
    Order memory temp = orderBook.orders[index1];
    orderBook.orders[index1] = orderBook.orders[index2];
    orderBook.orders[index2] = temp;
    orderBook.orderIndexById[orderBook.orders[index1].id] = index1;
    orderBook.orderIndexById[orderBook.orders[index2].id] = index2;
  }

  /// @notice Standard heap sift up operation.
  /// @param orderBook The `OrderBook` instance.
  /// @param index The index of the element to move.
  /// @return The index of the slot the element has been moved to.
  function siftUp(OrderBook storage orderBook, uint256 index) private returns (uint256) {
    while (index > 0) {
      uint256 parentIndex = parentOf(index);
      if (compareOrders(orderBook, index, parentIndex)) {
        swap(orderBook, index, parentIndex);
        index = parentIndex;
      } else {
        return index;
      }
    }
    return index;
  }

  /// @notice Standard heap sift down operation.
  /// @param orderBook The `OrderBook` instance.
  /// @param index The index of the element to move.
  /// @return The index of the slot the element has been moved to.
  function siftDown(OrderBook storage orderBook, uint256 index) private returns (uint256) {
    while (leftChildOf(index) < orderBook.orders.length) {
      uint256 leftChildIndex = leftChildOf(index);
      uint256 rightChildIndex = rightChildOf(index);
      if (compareOrders(orderBook, rightChildIndex, leftChildIndex)) {
        if (compareOrders(orderBook, index, rightChildIndex)) {
          swap(orderBook, index, rightChildIndex);
          index = rightChildIndex;
        } else {
          return index;
        }
      } else {
        if (compareOrders(orderBook, index, leftChildIndex)) {
          swap(orderBook, index, leftChildIndex);
          index = leftChildIndex;
        } else {
          return index;
        }
      }
    }
    return index;
  }

  /// @notice Returns the smaller of two values.
  /// @param a The first value.
  /// @param b The second value.
  /// @return The smaller of `a` and `b`.
  function min(uint256 a, uint256 b) private pure returns (uint256) {
    return b < a ? b : a;
  }

  /// @notice Returns a paginated slice of orders from the heap array.
  /// @param orderBook The `OrderBook` instance.
  /// @param offset The zero-based index of the first order to return.
  /// @param count The maximum number of orders to return.
  /// @return orders An array of at most `count` orders starting at `offset`.
  function getOrders(
    OrderBook storage orderBook,
    uint256 offset,
    uint256 count
  ) external view returns (Order[] memory orders) {
    orders = new Order[](min(orderBook.orders.length - offset, count));
    for (uint256 i = 0; i < orders.length; ++i) {
      orders[i] = orderBook.orders[i + offset];
    }
  }

  /// @notice Returns a paginated slice of orders placed by a specific issuer.
  /// @param orderBook The `OrderBook` instance.
  /// @param issuer The address whose orders to retrieve.
  /// @param offset The zero-based index into the issuer's order list to start from.
  /// @param count The maximum number of orders to return.
  /// @return orders An array of at most `count` orders from `issuer` starting at `offset`.
  function getOrdersFrom(
    OrderBook storage orderBook,
    address issuer,
    uint256 offset,
    uint256 count
  ) external view returns (Order[] memory orders) {
    uint256[] storage orderIds = orderBook.orderIdsByIssuer[issuer];
    orders = new Order[](min(orderIds.length - offset, count));
    for (uint256 i = 0; i < orders.length; ++i) {
      orders[i] = orderBook.orders[orderBook.orderIndexById[orderIds[i + offset]]];
    }
  }

  /// @notice Returns the current market price as the unit-weighted average price across all active
  ///   orders.
  /// @dev Returns 0 when the order book is empty.
  /// @param orderBook The `OrderBook` instance.
  /// @return The weighted average price, or 0 if there are no active orders.
  function getAveragePrice(OrderBook storage orderBook) external view returns (uint256) {
    if (orderBook.unitSum != 0) {
      return orderBook.priceSum / orderBook.unitSum;
    } else {
      return 0;
    }
  }

  /// @notice Adds a new order to the book.
  /// @param orderBook The `OrderBook` instance.
  /// @param issuer The account placing the order. Must not be zero.
  /// @param units The number of units to buy or sell. Must be greater than 0.
  /// @param price The limit price per unit. Must be greater than 0.
  /// @return id The ID assigned to the newly created order.
  function queueOrder(
    OrderBook storage orderBook,
    address issuer,
    uint256 units,
    uint256 price
  ) external returns (uint256 id) {
    assert(issuer != address(0));
    if (units == 0 || price == 0) {
      revert InvalidArgument();
    }
    id = ++orderBook.lastOrderId;
    uint256 index = orderBook.orders.length;
    orderBook.orders.push(Order({id: id, issuer: issuer, units: units, price: price}));
    orderBook.orderIndexById[id] = index;
    siftUp(orderBook, index);
    orderBook.orderIdsByIssuer[issuer].push(id);
    orderBook.unitSum += units;
    orderBook.priceSum += price * units;
  }

  /// @notice Removes the order at the given heap index and restores heap invariants.
  /// @dev Uses a sift-up-then-swap-and-sift-down strategy to extract an arbitrary element.
  /// @param orderBook The `OrderBook` instance.
  /// @param index The heap array index of the order to extract.
  /// @return order The extracted order.
  function extractOrder(
    OrderBook storage orderBook,
    uint256 index
  ) private returns (Order memory order) {
    Order[] storage orders = orderBook.orders;
    assert(index < orders.length);
    order = orders[index];
    orders[index].price = 0;
    orders[index].id = 0;
    index = siftUp(orderBook, index);
    assert(index == 0);
    if (orders.length > 1) {
      swap(orderBook, 0, orders.length - 1);
      siftDown(orderBook, 0);
    }
    orders.pop();
    orderBook.orderIndexById[order.id] = 0;
  }

  /// @notice Cancels an active order, removing it from the book and restoring heap invariants.
  /// @param orderBook The `OrderBook` instance.
  /// @param issuer The address requesting the cancellation. Must match the order's original issuer.
  /// @param id The ID of the order to cancel. Must be a valid active order ID.
  /// @return order The cancelled order.
  function cancelOrder(
    OrderBook storage orderBook,
    address issuer,
    uint256 id
  ) external returns (Order memory order) {
    if (issuer == address(0) || id == 0) {
      revert InvalidArgument();
    }
    uint256 index = orderBook.orderIndexById[id];
    order = orderBook.orders[index];
    if (order.id != id) {
      revert InvalidOrderId(id);
    }
    if (order.issuer != issuer) {
      revert PermissionDenied(id, order.issuer, issuer);
    }
    extractOrder(orderBook, index);
  }

  /// @notice Fulfills as many orders as possible using the given number of units at any price.
  /// @param orderBook The `OrderBook` instance.
  /// @param units The total number of units to fill.
  /// @return matches An array of orders (or partial orders) that were matched and filled.
  function fulfill(
    OrderBook storage orderBook,
    uint256 units
  ) external returns (Order[] memory matches) {
    Order[] storage orders = orderBook.orders;
    while (orders.length > 0) {
      if (units < orders[0].units) {
        // TODO
      } else {
        // TODO
      }
    }
  }

  /// @notice Fulfills orders up to the given price limit, consuming as many units as possible.
  /// @param orderBook The `OrderBook` instance.
  /// @param units The total number of units to fill.
  /// @param price The maximum (for buy books) or minimum (for sell books) acceptable price per
  ///   unit.
  /// @return matches An array of orders (or partial orders) that were matched and filled.
  function fulfillAt(
    OrderBook storage orderBook,
    uint256 units,
    uint256 price
  ) external returns (Order[] memory matches) {
    Order[] storage orders = orderBook.orders;
    while (orders.length > 0 && orders[0].price <= price) {
      // TODO
    }
  }
}
