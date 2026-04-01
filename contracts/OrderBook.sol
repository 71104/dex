// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

struct Order {
  uint256 id;
  address owner;
  uint256 units;
  uint256 price;
}

struct OrderBook {
  uint256 nextOrderId;
  Order[] orders;
  mapping(address => uint256[]) orderIdsByOwner;
  uint256 unitSum;
  uint256 priceSum;
}

library OrderBookMethods {
  function length(OrderBook storage orderBook) public view returns (uint256) {
    return orderBook.orders.length;
  }

  function parentOf(uint256 index) private pure returns (uint256) {
    return (index - 1) / 2;
  }

  function swap(OrderBook storage orderBook, uint256 index1, uint256 index2) private {
    Order memory temp = orderBook.orders[index1];
    orderBook.orders[index1] = orderBook.orders[index2];
    orderBook.orders[index2] = temp;
  }

  function siftUp(OrderBook storage orderBook, uint256 index) private returns (uint256) {
    while (index > 0) {
      uint256 parentIndex = parentOf(index);
      Order storage order = orderBook.orders[index];
      Order storage parent = orderBook.orders[parentIndex];
      if (order.price < parent.price) {
        swap(orderBook, index, parentIndex);
        index = parentIndex;
      } else {
        return index;
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

  function getAveragePrice(OrderBook storage orderBook) public view returns (uint256) {
    if (orderBook.unitSum != 0) {
      return orderBook.priceSum / orderBook.unitSum;
    } else {
      return 0;
    }
  }

  function addOrder(
    OrderBook storage orderBook,
    address owner,
    uint256 units,
    uint256 price
  ) public returns (uint256 id) {
    id = orderBook.nextOrderId++;
    uint256 index = orderBook.orders.length;
    orderBook.orders.push(Order({id: id, owner: owner, units: units, price: price}));
    siftUp(orderBook, index);
    orderBook.orderIdsByOwner[owner].push(id);
    orderBook.unitSum += units;
    orderBook.priceSum += price;
  }

  function fulfill(
    OrderBook storage orderBook,
    uint256 units
  ) public returns (Order[] memory matches) {
    // TODO
  }

  function fulfillAt(
    OrderBook storage orderBook,
    uint256 units,
    uint256 price
  ) public returns (Order[] memory matches) {
    // TODO
  }
}
