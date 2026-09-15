// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MarfaSpiritMembership} from "../src/MarfaSpiritMembership.sol";

/**
 * @notice Deploys the membership contract and seeds the initial tiers.
 *
 * Required env vars:
 *   ADMIN_ADDRESS     - multisig / owner that gets DEFAULT_ADMIN_ROLE + MANAGER_ROLE
 *   SIGNER_ADDRESS    - address of the backend voucher-signing key (Firebase function secret)
 *   PAYOUT_ADDRESS    - where `withdraw` sends ETH
 *   BASE_URI          - e.g. https://<region>-<project>.cloudfunctions.net/metadata/
 *   ROYALTY_RECEIVER  - ERC-2981 receiver (may equal PAYOUT_ADDRESS)
 *   ROYALTY_BPS       - e.g. 500 for 5%
 *
 * Usage:
 *   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
 */
contract Deploy is Script {
    function run() external returns (MarfaSpiritMembership nft) {
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address signer = vm.envAddress("SIGNER_ADDRESS");
        address payout = vm.envAddress("PAYOUT_ADDRESS");
        string memory baseURI = vm.envString("BASE_URI");
        address royaltyReceiver = vm.envOr("ROYALTY_RECEIVER", payout);
        uint96 royaltyBps = uint96(vm.envOr("ROYALTY_BPS", uint256(500)));

        vm.startBroadcast();

        nft = new MarfaSpiritMembership(admin, signer, payout, baseURI, royaltyReceiver, royaltyBps);

        // Initial tiers. The broadcaster must hold MANAGER_ROLE for these to succeed, so when
        // ADMIN_ADDRESS is a multisig, skip seeding here and create tiers from the admin UI.
        //
        // Launch model: ONE open tier, "Founders 2026", capped at 50 (one per wallet). Sotolero and
        // Godbold exist but stay closed; next year staff open them and Founders holders trade in
        // (`rollover`): the Founders token is burned AND the trade-in price is paid, which is less
        // than joining that tier cold.
        if (nft.hasRole(nft.MANAGER_ROLE(), msg.sender)) {
            uint8 founders = nft.createTier("Founders 2026", 0.1 ether, 0.05 ether, 50, 1, true);
            uint8 sotolero = nft.createTier("Sotolero", 0.05 ether, 0.03 ether, 500, 2, false);
            uint8 godbold = nft.createTier("Godbold", 0.2 ether, 0.1 ether, 75, 1, false);
            nft.setTierRollover(sotolero, uint8(1) << founders, 0.02 ether); // burn + 0.02 (vs 0.05 cold)
            nft.setTierRollover(godbold, uint8(1) << founders, 0.1 ether); // burn + 0.10 (vs 0.20 cold)
        }

        vm.stopBroadcast();

        console2.log("MarfaSpiritMembership deployed at", address(nft));
    }
}
