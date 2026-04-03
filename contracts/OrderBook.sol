// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @notice Represents an order.
/// @dev It's unspecified whether this is a buy or sell order because our `OrderBook` data structure
///   works for both and each market has two separate order books, one for buy orders and one for
///   sell orders.
/// @dev Orders are identified by an incremental ID (the `id` field) that's unique per order book.
///   The lowest valid ID is 1 because 0 is used as a sentinel value.
struct Order {
  uint256 id;
  address issuer;
  uint256 units;
  uint256 price;
}

/// @notice An order book for either buy orders or sell orders.
/// @dev At any given time each market has two order books: one for buy orders and one for sell
///   orders.
/// @dev `OrderBook` is implemented as a min-heap of `Order`s ordered by price, so that the order at
///   the top has the lowest price. Two orders with the same price are ordered by ID low-first.
///   Since order IDs are incremental, ordering by lowest ID is equivalent to ordering
///   chronologically, so that if two orders have the same price the one that came first is
///   fulfilled first.
struct OrderBook {
  uint256 lastOrderId;
  Order[] orders;
  mapping(uint256 => uint256) orderIndexById;
  mapping(address => uint256[]) orderIdsByIssuer;
  uint256 unitSum;
  uint256 priceSum;
}

library OrderBookMethods {
  error InvalidArgument();
  error InvalidOrderId(uint256 orderId);
  error PermissionDenied(uint256 orderId, address originalIssuer, address canceler);

  /// @return The number of orders in this book.
  function length(OrderBook storage orderBook) public view returns (uint256) {
    return orderBook.orders.length;
  }

  /// @return The index of the parent of the element at `index`.
  function parentOf(uint256 index) private pure returns (uint256) {
    assert(index > 0);
    return (index - 1) / 2;
  }

  /// @return The index of the left child of the element at `index`.
  function leftChildOf(uint256 index) private pure returns (uint256) {
    return index * 2 + 1;
  }

  /// @return The index of the right child of the element at `index`.
  function rightChildOf(uint256 index) private pure returns (uint256) {
    return index * 2 + 2;
  }

  /// @notice Compares two orders based on the heap order and returns true iff the LHS is strictly
  ///   less (ie. more extreme) than the RHS.
  /// @param lhs The left hand side of the comparison.
  /// @param rhs The right hand side of the comparison.
  /// @return True iff the LHS is strictly less than the RHS based on the heap order.
  function compareOrders(Order storage lhs, Order storage rhs) private view returns (bool) {
    return lhs.price < rhs.price || (lhs.price == rhs.price && lhs.id < rhs.id);
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
      Order storage order = orderBook.orders[index];
      Order storage parent = orderBook.orders[parentIndex];
      if (compareOrders(order, parent)) {
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
    Order[] storage orders = orderBook.orders;
    while (leftChildOf(index) < orderBook.orders.length) {
      uint256 leftChildIndex = leftChildOf(index);
      uint256 rightChildIndex = rightChildOf(index);
      if (compareOrders(orders[rightChildIndex], orders[leftChildIndex])) {
        if (compareOrders(orders[index], orders[rightChildIndex])) {
          swap(orderBook, index, rightChildIndex);
          index = rightChildIndex;
        } else {
          return index;
        }
      } else {
        if (compareOrders(orders[index], orders[leftChildIndex])) {
          swap(orderBook, index, leftChildIndex);
          index = leftChildIndex;
        } else {
          return index;
        }
      }
    }
    return index;
  }

  function min(uint256 a, uint256 b) private pure returns (uint256) {
    return b < a ? b : a;
  }

  function getOrders(
    OrderBook storage orderBook,
    uint256 offset,
    uint256 count
  ) public view returns (Order[] memory orders) {
    orders = new Order[](min(orderBook.orders.length - offset, count));
    for (uint256 i = 0; i < orders.length; ++i) {
      orders[i] = orderBook.orders[i + offset];
    }
  }

  function getOrdersFrom(
    OrderBook storage orderBook,
    address issuer,
    uint256 offset,
    uint256 count
  ) public view returns (Order[] memory orders) {
    uint256[] storage orderIds = orderBook.orderIdsByIssuer[issuer];
    orders = new Order[](min(orderIds.length - offset, count));
    for (uint256 i = 0; i < orders.length; ++i) {
      orders[i] = orderBook.orders[orderBook.orderIndexById[orderIds[i + offset]]];
    }
  }

  function getAveragePrice(OrderBook storage orderBook) public view returns (uint256) {
    if (orderBook.unitSum != 0) {
      return orderBook.priceSum / orderBook.unitSum;
    } else {
      return 0;
    }
  }

  function addOrder(
    OrderBook storage orderBook,
    address issuer,
    uint256 units,
    uint256 price
  ) public returns (uint256 id) {
    if (issuer == address(0) || units == 0 || price == 0) {
      revert InvalidArgument();
    }
    id = ++orderBook.lastOrderId;
    uint256 index = orderBook.orders.length;
    orderBook.orders.push(Order({id: id, issuer: issuer, units: units, price: price}));
    orderBook.orderIndexById[id] = index;
    siftUp(orderBook, index);
    orderBook.orderIdsByIssuer[issuer].push(id);
    orderBook.unitSum += units;
    orderBook.priceSum += price;
  }

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

  function cancelOrder(
    OrderBook storage orderBook,
    address issuer,
    uint256 id
  ) public returns (Order memory order) {
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

  function fulfill(
    OrderBook storage orderBook,
    uint256 units
  ) public returns (Order[] memory matches) {
    Order[] storage orders = orderBook.orders;
    while (orders.length > 0) {
      if (units < orders[0].units) {
        // TODO
      } else {
        // TODO
      }
    }
  }

  function fulfillAt(
    OrderBook storage orderBook,
    uint256 units,
    uint256 price
  ) public returns (Order[] memory matches) {
    Order[] storage orders = orderBook.orders;
    while (orders.length > 0 && orders[0].price <= price) {
      // TODO
    }
  }
}
