// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {MarfaSpiritMembership} from "../../src/MarfaSpiritMembership.sol";

/// @dev Tries to re-enter `mint` from `onERC721Received` using a second valid voucher.
contract ReentrantMinter is IERC721Receiver {
    MarfaSpiritMembership public immutable target;
    MarfaSpiritMembership.MintVoucher public second;
    bytes public secondSig;
    bool public reentered;

    constructor(MarfaSpiritMembership _target) {
        target = _target;
    }

    function setSecond(MarfaSpiritMembership.MintVoucher calldata v, bytes calldata sig) external {
        second = v;
        secondSig = sig;
    }

    function attack(MarfaSpiritMembership.MintVoucher calldata v, bytes calldata sig) external payable {
        target.mint{value: msg.value / 2}(v, sig);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        if (!reentered) {
            reentered = true;
            // Re-entrancy attempt: should revert with ReentrancyGuardReentrantCall.
            target.mint{value: address(this).balance}(second, secondSig);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev Payout address that re-enters `withdraw` when it receives ETH.
contract ReentrantPayout {
    MarfaSpiritMembership public immutable target;
    uint256 public hits;

    constructor(MarfaSpiritMembership _target) {
        target = _target;
    }

    receive() external payable {
        hits++;
        if (hits < 3) {
            target.withdraw();
        }
    }
}

/// @dev Payout address that always rejects ETH.
contract RejectingPayout {
    receive() external payable {
        revert("no");
    }
}

/// @dev Holds a token, then tries to re-enter `rollover` from `onERC721Received` during the new mint.
contract ReentrantRollover is IERC721Receiver {
    MarfaSpiritMembership public immutable target;
    bool public armed;
    uint256 public tokenId;
    uint8 public toTier;

    constructor(MarfaSpiritMembership _target) {
        target = _target;
    }

    function mint(MarfaSpiritMembership.MintVoucher calldata v, bytes calldata sig) external payable {
        target.mint{value: msg.value}(v, sig);
    }

    function attack(uint256 _tokenId, uint8 _toTier) external {
        armed = true;
        tokenId = _tokenId;
        toTier = _toTier;
        target.rollover(_tokenId, _toTier);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external override returns (bytes4) {
        if (armed) {
            armed = false;
            // The old token is already burned here; any re-entry must be blocked by the guard first.
            target.rollover(tokenId, toTier);
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
