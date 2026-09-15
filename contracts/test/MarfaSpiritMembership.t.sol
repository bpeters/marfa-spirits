// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

import {MarfaSpiritMembership} from "../src/MarfaSpiritMembership.sol";
import {ReentrantMinter, ReentrantPayout, ReentrantRollover, RejectingPayout} from "./mocks/Attackers.sol";

contract MarfaSpiritMembershipTest is Test {
    MarfaSpiritMembership internal nft;

    address internal admin = makeAddr("admin");
    address internal payout = makeAddr("payout");
    address internal royalty = makeAddr("royalty");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal mallory = makeAddr("mallory");

    uint256 internal signerPk = 0xA11CE;
    address internal signer;
    uint256 internal roguePk = 0xBAD;

    uint8 internal constant SOTOLERO = 0; // tier 0
    uint8 internal constant GODBOLD = 1; // tier 1

    uint96 internal constant PRICE_0 = 0.05 ether;
    uint96 internal constant RENEW_0 = 0.03 ether;
    uint96 internal constant PRICE_1 = 0.2 ether;
    uint96 internal constant RENEW_1 = 0.1 ether;

    uint256 internal nextNonce = 1;

    bytes32 internal MANAGER_ROLE;
    bytes32 internal SIGNER_ROLE;
    bytes32 internal DEFAULT_ADMIN_ROLE;

    function setUp() public {
        signer = vm.addr(signerPk);
        vm.warp(1_800_000_000);

        nft = new MarfaSpiritMembership(admin, signer, payout, "https://api.example.com/metadata/", royalty, 500);
        MANAGER_ROLE = nft.MANAGER_ROLE();
        SIGNER_ROLE = nft.SIGNER_ROLE();
        DEFAULT_ADMIN_ROLE = nft.DEFAULT_ADMIN_ROLE();

        vm.startPrank(admin);
        nft.createTier("Sotolero", PRICE_0, RENEW_0, 100, 2, true);
        nft.createTier("Godbold", PRICE_1, RENEW_1, 10, 1, true);
        nft.setWalletVerified(bob, true); // bob is a verified recipient for transfer tests
        vm.stopPrank();

        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
        vm.deal(mallory, 10 ether);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _voucher(address to, uint8 tierId) internal returns (MarfaSpiritMembership.MintVoucher memory v) {
        v = MarfaSpiritMembership.MintVoucher({to: to, tierId: tierId, nonce: nextNonce++, deadline: block.timestamp + 1 hours});
    }

    function _sign(uint256 pk, MarfaSpiritMembership.MintVoucher memory v) internal view returns (bytes memory) {
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(pk, nft.hashVoucher(v));
        return abi.encodePacked(r, s, vv);
    }

    function _mintFor(address to, uint8 tierId) internal returns (uint256 tokenId) {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(to, tierId);
        bytes memory sig = _sign(signerPk, v);
        uint96 price = nft.getTier(tierId).mintPrice;
        vm.prank(to);
        tokenId = nft.mint{value: price}(v, sig);
    }

    function _walletVoucher(address wallet) internal returns (MarfaSpiritMembership.WalletVoucher memory v) {
        v = MarfaSpiritMembership.WalletVoucher({wallet: wallet, nonce: nextNonce++, deadline: block.timestamp + 1 hours});
    }

    function _signWallet(uint256 pk, MarfaSpiritMembership.WalletVoucher memory v) internal view returns (bytes memory) {
        (uint8 vv, bytes32 r, bytes32 s) = vm.sign(pk, nft.hashWalletVoucher(v));
        return abi.encodePacked(r, s, vv);
    }

    function _createPerk(uint8 mask, uint32 maxClaims) internal returns (uint256) {
        vm.prank(admin);
        return nft.createPerk(mask, uint64(block.timestamp), 0, maxClaims, "ipfs://perk");
    }

    // ------------------------------------------------------------------
    // Constructor / roles
    // ------------------------------------------------------------------

    function test_constructor_setsRolesAndConfig() public view {
        assertTrue(nft.hasRole(nft.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(nft.hasRole(nft.MANAGER_ROLE(), admin));
        assertTrue(nft.hasRole(nft.SIGNER_ROLE(), signer));
        assertEq(nft.payoutAddress(), payout);
        assertEq(nft.membershipDuration(), 365 days);
        assertEq(nft.tierCount(), 2);
        (address r, uint256 amt) = nft.royaltyInfo(1, 10_000);
        assertEq(r, royalty);
        assertEq(amt, 500);
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(MarfaSpiritMembership.ZeroAddress.selector);
        new MarfaSpiritMembership(address(0), signer, payout, "", royalty, 500);
        vm.expectRevert(MarfaSpiritMembership.ZeroAddress.selector);
        new MarfaSpiritMembership(admin, address(0), payout, "", royalty, 500);
        vm.expectRevert(MarfaSpiritMembership.ZeroAddress.selector);
        new MarfaSpiritMembership(admin, signer, address(0), "", royalty, 500);
    }

    function test_supportsInterfaces() public view {
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721Enumerable).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(nft.supportsInterface(type(IAccessControl).interfaceId));
    }

    // ------------------------------------------------------------------
    // Tiers
    // ------------------------------------------------------------------

    function test_createTier_onlyManager() public {
        vm.prank(mallory);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, MANAGER_ROLE)
        );
        nft.createTier("X", 1, 1, 1, 1, true);
    }

    function test_createTier_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(MarfaSpiritMembership.InvalidSupply.selector);
        nft.createTier("X", 1, 1, 0, 1, true);
        vm.expectRevert(MarfaSpiritMembership.InvalidSupply.selector);
        nft.createTier("X", 1, 1, 1, 0, true);

        // Fill to MAX_TIERS then one more fails.
        for (uint256 i = nft.tierCount(); i < nft.MAX_TIERS(); i++) {
            nft.createTier("T", 1, 1, 1, 1, true);
        }
        vm.expectRevert(MarfaSpiritMembership.MaxTiersReached.selector);
        nft.createTier("T", 1, 1, 1, 1, true);
        vm.stopPrank();
    }

    function test_updateTier_cannotDropSupplyBelowMinted() public {
        _mintFor(alice, SOTOLERO);
        _mintFor(bob, SOTOLERO);
        vm.startPrank(admin);
        vm.expectRevert(MarfaSpiritMembership.InvalidSupply.selector);
        nft.updateTier(SOTOLERO, PRICE_0, RENEW_0, 1, 2, true);
        nft.updateTier(SOTOLERO, PRICE_0, RENEW_0, 2, 2, false); // exactly minted is fine
        vm.stopPrank();
        assertEq(nft.getTier(SOTOLERO).maxSupply, 2);
        assertFalse(nft.getTier(SOTOLERO).active);
    }

    function test_updateTier_invalidTier() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.InvalidTier.selector, 9));
        nft.updateTier(9, 1, 1, 1, 1, true);
    }

    // ------------------------------------------------------------------
    // Mint
    // ------------------------------------------------------------------

    function test_mint_happyPath() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);

        vm.expectEmit(true, true, true, true);
        emit MarfaSpiritMembership.MembershipMinted(1, alice, SOTOLERO, uint64(block.timestamp + 365 days), v.nonce);

        vm.prank(alice);
        uint256 tokenId = nft.mint{value: PRICE_0}(v, sig);

        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertTrue(nft.isActive(1));
        MarfaSpiritMembership.Membership memory m = nft.membershipOf(1);
        assertEq(m.tierId, SOTOLERO);
        assertEq(m.expiresAt, block.timestamp + 365 days);
        assertTrue(nft.nonceUsed(v.nonce));
        assertEq(nft.getTier(SOTOLERO).minted, 1);
        assertEq(nft.mintedPerWallet(alice, SOTOLERO), 1);
        assertEq(address(nft).balance, PRICE_0);
        assertEq(nft.tokenURI(1), "https://api.example.com/metadata/1");
    }

    function test_mint_revertsIfCallerIsNotRecipient() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.prank(mallory);
        vm.expectRevert(MarfaSpiritMembership.NotVoucherRecipient.selector);
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_revertsOnExpiredVoucher() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.warp(v.deadline + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.VoucherExpired.selector, v.deadline));
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_revertsOnReplayedNonce() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.startPrank(alice);
        nft.mint{value: PRICE_0}(v, sig);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.VoucherAlreadyUsed.selector, v.nonce));
        nft.mint{value: PRICE_0}(v, sig);
        vm.stopPrank();
    }

    function test_mint_revertsOnRogueSigner() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(roguePk, v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.InvalidVoucherSigner.selector, vm.addr(roguePk)));
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_revertsOnTamperedVoucher() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, GODBOLD);
        bytes memory sig = _sign(signerPk, v);
        v.tierId = SOTOLERO; // downgrade price after signing
        vm.prank(alice);
        // Recovered signer is some random address without SIGNER_ROLE.
        vm.expectRevert();
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_revertsOnMalformedSignature() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ECDSA.ECDSAInvalidSignatureLength.selector, 3));
        nft.mint{value: PRICE_0}(v, hex"010203");
    }

    function test_mint_revertsOnInvalidTier() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, 7);
        bytes memory sig = _sign(signerPk, v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.InvalidTier.selector, 7));
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_revertsOnInactiveTier() public {
        vm.prank(admin);
        nft.updateTier(SOTOLERO, PRICE_0, RENEW_0, 100, 2, false);
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.TierInactive.selector, SOTOLERO));
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_revertsWhenSoldOut() public {
        vm.prank(admin);
        nft.updateTier(SOTOLERO, PRICE_0, RENEW_0, 1, 2, true);
        _mintFor(alice, SOTOLERO);
        MarfaSpiritMembership.MintVoucher memory v = _voucher(bob, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.TierSoldOut.selector, SOTOLERO));
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_enforcesWalletLimit() public {
        _mintFor(alice, GODBOLD); // maxPerWallet = 1
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, GODBOLD);
        bytes memory sig = _sign(signerPk, v);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.WalletLimitReached.selector, GODBOLD));
        nft.mint{value: PRICE_1}(v, sig);

        // A different tier is still allowed.
        _mintFor(alice, SOTOLERO);
        assertEq(nft.balanceOf(alice), 2);
    }

    function test_mint_revertsOnWrongPayment() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.IncorrectPayment.selector, PRICE_0, PRICE_0 - 1));
        nft.mint{value: PRICE_0 - 1}(v, sig);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.IncorrectPayment.selector, PRICE_0, PRICE_0 + 1));
        nft.mint{value: PRICE_0 + 1}(v, sig);
        vm.stopPrank();
    }

    function test_mint_revertsWhenPaused() public {
        vm.prank(admin);
        nft.pause();
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_mint_reentrancyBlocked() public {
        ReentrantMinter attacker = new ReentrantMinter(nft);
        vm.deal(address(attacker), 1 ether);

        MarfaSpiritMembership.MintVoucher memory v1 = _voucher(address(attacker), SOTOLERO);
        MarfaSpiritMembership.MintVoucher memory v2 = _voucher(address(attacker), SOTOLERO);
        attacker.setSecond(v2, _sign(signerPk, v2));
        bytes memory sig1 = _sign(signerPk, v1);

        // Inner mint reverts with ReentrancyGuardReentrantCall; the receiver hook bubbles it up,
        // so the whole outer mint reverts and no state changes persist.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.attack{value: PRICE_0 * 2}(v1, sig1);

        assertEq(nft.totalSupply(), 0);
        assertFalse(nft.nonceUsed(v1.nonce));
        assertFalse(nft.nonceUsed(v2.nonce));
    }

    function test_revokedSignerCannotMint() public {
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.prank(admin);
        nft.revokeRole(SIGNER_ROLE, signer);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.InvalidVoucherSigner.selector, signer));
        nft.mint{value: PRICE_0}(v, sig);
    }

    function test_contractRejectsPlainEther() public {
        (bool ok,) = address(nft).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------------------
    // Renew
    // ------------------------------------------------------------------

    function test_renew_extendsActiveMembership() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint64 before = nft.membershipOf(id).expiresAt;
        vm.warp(block.timestamp + 100 days);

        vm.expectEmit(true, true, false, true);
        emit MarfaSpiritMembership.MembershipRenewed(id, bob, before + 365 days);
        vm.prank(bob); // anyone can pay to renew (gifting)
        nft.renew{value: RENEW_0}(id);

        assertEq(nft.membershipOf(id).expiresAt, before + 365 days);
    }

    function test_renew_expiredStartsFromNow() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.warp(block.timestamp + 400 days);
        assertFalse(nft.isActive(id));

        vm.prank(alice);
        nft.renew{value: RENEW_0}(id);
        assertEq(nft.membershipOf(id).expiresAt, block.timestamp + 365 days);
        assertTrue(nft.isActive(id));
    }

    function test_renew_usesTierRenewalPrice() public {
        uint256 id = _mintFor(alice, GODBOLD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.IncorrectPayment.selector, RENEW_1, RENEW_0));
        nft.renew{value: RENEW_0}(id);
    }

    function test_renew_revertsOnNonexistentToken() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 42));
        nft.renew{value: RENEW_0}(42);
    }

    function test_renew_revertsWhenPaused() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(admin);
        nft.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.renew{value: RENEW_0}(id);
    }

    function testFuzz_renew_alwaysExtendsByDuration(uint32 elapsed) public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint64 mintedExpiry = nft.membershipOf(id).expiresAt;
        vm.warp(block.timestamp + elapsed);
        uint64 expectedBase = mintedExpiry > block.timestamp ? mintedExpiry : uint64(block.timestamp);

        vm.prank(alice);
        nft.renew{value: RENEW_0}(id);
        assertEq(nft.membershipOf(id).expiresAt, expectedBase + 365 days);
    }


    // ------------------------------------------------------------------
    // Rollover (burn this year's token for next year's tier)
    // ------------------------------------------------------------------

    uint8 internal constant NEXT = 2; // created in _setupNextYear

    function _setupNextYear(uint96 rolloverPrice) internal {
        vm.startPrank(admin);
        nft.createTier("Members 2027", 0.08 ether, 0.04 ether, 50, 1, true);
        nft.setTierRollover(NEXT, uint8(1) << SOTOLERO, rolloverPrice); // accepts Sotolero only
        vm.stopPrank();
    }

    function test_rollover_burnsOldAndMintsNew_freeWhenPriceZero() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        uint64 oldExpiry = nft.membershipOf(id).expiresAt;
        vm.warp(block.timestamp + 300 days);

        (bool ok, string memory reason) = nft.canRollover(id, NEXT);
        assertTrue(ok);
        assertEq(reason, "");

        vm.expectEmit(true, true, true, true);
        emit MarfaSpiritMembership.MembershipRolledOver(id, 2, alice, SOTOLERO, NEXT, oldExpiry + 365 days);
        vm.prank(alice);
        uint256 newId = nft.rollover(id, NEXT);

        assertEq(newId, 2);
        assertEq(nft.ownerOf(newId), alice);
        assertEq(nft.balanceOf(alice), 1);
        assertEq(nft.totalSupply(), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        nft.ownerOf(id);

        MarfaSpiritMembership.Membership memory m = nft.membershipOf(newId);
        assertEq(m.tierId, NEXT);
        assertEq(m.expiresAt, oldExpiry + 365 days); // unexpired 65 days carried over
        assertEq(nft.getTier(NEXT).minted, 1);
        assertEq(nft.mintedPerWallet(alice, NEXT), 1);
        assertEq(address(nft).balance, PRICE_0); // nothing extra paid
    }

    function test_rollover_chargesRolloverPrice() public {
        _setupNextYear(0.02 ether);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.IncorrectPayment.selector, 0.02 ether, 0));
        nft.rollover(id, NEXT);
        nft.rollover{value: 0.02 ether}(id, NEXT);
        vm.stopPrank();
        assertEq(address(nft).balance, PRICE_0 + 0.02 ether);
    }

    function test_rollover_expiredStartsFromNow_withinGrace() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.warp(block.timestamp + 365 days + 10 days); // expired 10 days ago, grace is 30
        assertFalse(nft.isActive(id));
        vm.prank(alice);
        uint256 newId = nft.rollover(id, NEXT);
        assertEq(nft.membershipOf(newId).expiresAt, block.timestamp + 365 days);
    }

    function test_rollover_revertsAfterGrace() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.warp(block.timestamp + 365 days + 31 days);
        (bool ok, string memory reason) = nft.canRollover(id, NEXT);
        assertFalse(ok);
        assertEq(reason, "ROLLOVER_WINDOW_CLOSED");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.RolloverWindowClosed.selector, id));
        nft.rollover(id, NEXT);
    }

    function test_rollover_zeroGraceRequiresActive() public {
        _setupNextYear(0);
        vm.prank(admin);
        nft.setRolloverGracePeriod(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.warp(block.timestamp + 365 days + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.RolloverWindowClosed.selector, id));
        nft.rollover(id, NEXT);
    }

    function test_rollover_revertsForUnacceptedTier() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, GODBOLD); // NEXT accepts Sotolero only
        (bool ok, string memory reason) = nft.canRollover(id, NEXT);
        assertFalse(ok);
        assertEq(reason, "ROLLOVER_NOT_ACCEPTED");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.RolloverNotAccepted.selector, GODBOLD, NEXT));
        nft.rollover{value: 0}(id, NEXT);
    }

    function test_rollover_revertsForNonOwnerAndOperators() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(alice);
        nft.setApprovalForAll(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.NotTokenOwner.selector, id));
        nft.rollover(id, NEXT);
    }

    function test_rollover_respectsInactiveSoldOutAndWalletLimit() public {
        _setupNextYear(0);
        uint256 a = _mintFor(alice, SOTOLERO);
        uint256 a2 = _mintFor(alice, SOTOLERO); // maxPerWallet for Sotolero is 2
        uint256 b = _mintFor(bob, SOTOLERO);

        vm.prank(admin);
        nft.updateTier(NEXT, 0.08 ether, 0.04 ether, 50, 1, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.TierInactive.selector, NEXT));
        nft.rollover(a, NEXT);

        vm.prank(admin);
        nft.updateTier(NEXT, 0.08 ether, 0.04 ether, 1, 1, true); // supply 1
        vm.prank(alice);
        nft.rollover(a, NEXT);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.TierSoldOut.selector, NEXT));
        nft.rollover(b, NEXT);

        vm.prank(admin);
        nft.updateTier(NEXT, 0.08 ether, 0.04 ether, 50, 1, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.WalletLimitReached.selector, NEXT));
        nft.rollover(a2, NEXT); // alice already holds one NEXT token
    }

    function test_rollover_revertsWhenPaused() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(admin);
        nft.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.rollover(id, NEXT);
    }

    function test_rollover_newTokenCanRedeemNewTierPerks_oldClaimsGone() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkOld = _createPerk(uint8(1) << SOTOLERO, 0);
        uint256 perkNew = _createPerk(uint8(1) << NEXT, 0);
        vm.prank(alice);
        nft.redeem(id, perkOld);

        vm.prank(alice);
        uint256 newId = nft.rollover(id, NEXT);

        (bool ok,) = nft.canRedeem(newId, perkNew);
        assertTrue(ok);
        (bool okOld, string memory reason) = nft.canRedeem(newId, perkOld);
        assertFalse(okOld);
        assertEq(reason, "TIER_NOT_ELIGIBLE");
        assertTrue(nft.hasRedeemed(perkOld, id)); // history of the burned token is retained
    }

    function test_setTierRollover_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.InvalidTier.selector, 7));
        nft.setTierRollover(7, 1, 0);
        vm.expectRevert(MarfaSpiritMembership.InvalidTierMask.selector);
        nft.setTierRollover(GODBOLD, uint8(1) << GODBOLD, 0); // self
        vm.expectRevert(MarfaSpiritMembership.InvalidTierMask.selector);
        nft.setTierRollover(GODBOLD, 0x04, 0); // tier 2 doesn't exist yet
        nft.setTierRollover(GODBOLD, uint8(1) << SOTOLERO, 0.01 ether);
        vm.stopPrank();
        assertEq(nft.getTier(GODBOLD).rolloverFromMask, 1);
        assertEq(nft.getTier(GODBOLD).rolloverPrice, 0.01 ether);

        vm.prank(mallory);
        vm.expectRevert();
        nft.setTierRollover(GODBOLD, 1, 0);
    }

    function test_rollover_reentrancyBlocked() public {
        _setupNextYear(0);
        ReentrantRollover attacker = new ReentrantRollover(nft);
        // Give the attacker contract a Sotolero token via a voucher.
        MarfaSpiritMembership.MintVoucher memory v = _voucher(address(attacker), SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.deal(address(attacker), 1 ether);
        attacker.mint{value: PRICE_0}(v, sig);
        uint256 id = nft.tokensOfOwner(address(attacker))[0];

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.attack(id, NEXT);
        assertEq(nft.ownerOf(id), address(attacker)); // nothing changed
        assertEq(nft.getTier(NEXT).minted, 0);
    }


    // ------------------------------------------------------------------
    // Age-gated transfers (verified wallet registry)
    // ------------------------------------------------------------------

    function test_mint_marksMinterVerified() public {
        assertFalse(nft.isVerified(alice));
        MarfaSpiritMembership.MintVoucher memory v = _voucher(alice, SOTOLERO);
        bytes memory sig = _sign(signerPk, v);
        vm.expectEmit(true, true, false, true);
        emit MarfaSpiritMembership.WalletVerified(alice, signer);
        vm.prank(alice);
        nft.mint{value: PRICE_0}(v, sig);
        assertTrue(nft.isVerified(alice));
    }

    function test_transfer_toUnverifiedWalletReverts() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.RecipientNotVerified.selector, mallory));
        nft.transferFrom(alice, mallory, id);

        // safeTransferFrom and operator transfers are gated by the same hook.
        vm.prank(alice);
        nft.setApprovalForAll(bob, true);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.RecipientNotVerified.selector, mallory));
        nft.safeTransferFrom(alice, mallory, id);
    }

    function test_transfer_toVerifiedWalletSucceeds() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        MarfaSpiritMembership.WalletVoucher memory wv = _walletVoucher(mallory);
        bytes memory sig = _signWallet(signerPk, wv);
        // Anyone can submit the voucher (e.g. the marketplace or the buyer's friend).
        vm.prank(bob);
        nft.verifyWallet(wv, sig);
        assertTrue(nft.isVerified(mallory));
        assertTrue(nft.nonceUsed(wv.nonce));

        vm.prank(alice);
        nft.transferFrom(alice, mallory, id);
        assertEq(nft.ownerOf(id), mallory);
    }

    function test_verifyWallet_rejectsBadVouchers() public {
        MarfaSpiritMembership.WalletVoucher memory wv = _walletVoucher(mallory);
        bytes memory sig = _signWallet(signerPk, wv);
        nft.verifyWallet(wv, sig);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.VoucherAlreadyUsed.selector, wv.nonce));
        nft.verifyWallet(wv, sig);

        MarfaSpiritMembership.WalletVoucher memory w2 = _walletVoucher(alice);
        bytes memory rogue = _signWallet(roguePk, w2);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.InvalidVoucherSigner.selector, vm.addr(roguePk)));
        nft.verifyWallet(w2, rogue);

        bytes memory good = _signWallet(signerPk, w2);
        vm.warp(w2.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.VoucherExpired.selector, w2.deadline));
        nft.verifyWallet(w2, good);

        // A mint voucher signature cannot be replayed as a wallet voucher (different typehash).
        MarfaSpiritMembership.MintVoucher memory mv = _voucher(alice, SOTOLERO);
        bytes memory mintSig = _sign(signerPk, mv);
        MarfaSpiritMembership.WalletVoucher memory forged =
            MarfaSpiritMembership.WalletVoucher({wallet: alice, nonce: mv.nonce, deadline: mv.deadline});
        vm.expectRevert();
        nft.verifyWallet(forged, mintSig);
    }

    function test_verifyWallet_revertsWhenPaused() public {
        MarfaSpiritMembership.WalletVoucher memory wv = _walletVoucher(mallory);
        bytes memory sig = _signWallet(signerPk, wv);
        vm.prank(admin);
        nft.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.verifyWallet(wv, sig);
    }

    function test_setWalletVerified_managerOnly_andRevokeBlocksReceiving() public {
        vm.prank(mallory);
        vm.expectRevert();
        nft.setWalletVerified(mallory, true);

        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit MarfaSpiritMembership.WalletVerificationRevoked(bob, admin);
        nft.setWalletVerified(bob, false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.RecipientNotVerified.selector, bob));
        nft.transferFrom(alice, bob, id);

        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.ZeroAddress.selector);
        nft.setWalletVerified(address(0), true);
    }

    function test_revokedWallet_keepsTokenButCannotRollover() public {
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(admin);
        nft.setWalletVerified(alice, false);

        assertEq(nft.ownerOf(id), alice);
        (bool ok, string memory reason) = nft.canRollover(id, NEXT);
        assertFalse(ok);
        assertEq(reason, "WALLET_NOT_VERIFIED");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.RecipientNotVerified.selector, alice));
        nft.rollover(id, NEXT);
    }

    function test_burnPathIsNeverGated() public {
        // rollover burns then mints to the (verified) caller — works even though address(0) is unverified
        _setupNextYear(0);
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(alice);
        nft.rollover(id, NEXT);
        assertEq(nft.balanceOf(alice), 1);
    }

    // ------------------------------------------------------------------
    // Perks & redemption
    // ------------------------------------------------------------------

    function test_createPerk_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(MarfaSpiritMembership.InvalidTierMask.selector);
        nft.createPerk(0, 0, 0, 0, "");
        vm.expectRevert(MarfaSpiritMembership.InvalidTierMask.selector);
        nft.createPerk(0x04, 0, 0, 0, ""); // bit 2 but only tiers 0 and 1 exist
        vm.expectRevert(MarfaSpiritMembership.InvalidWindow.selector);
        nft.createPerk(0x01, 100, 100, 0, "");
        vm.stopPrank();

        vm.prank(mallory);
        vm.expectRevert();
        nft.createPerk(0x01, 0, 0, 0, "");
    }

    function test_redeem_happyPath() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x03, 50);

        (bool ok, string memory reason) = nft.canRedeem(id, perkId);
        assertTrue(ok);
        assertEq(reason, "");

        vm.expectEmit(true, true, true, true);
        emit MarfaSpiritMembership.PerkRedeemed(perkId, id, alice);
        vm.prank(alice);
        nft.redeem(id, perkId);

        assertTrue(nft.hasRedeemed(perkId, id));
        assertEq(nft.getPerk(perkId).claimed, 1);
    }

    function test_redeem_revertsOnDoubleClaim() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 0);
        vm.startPrank(alice);
        nft.redeem(id, perkId);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.AlreadyRedeemed.selector, perkId, id));
        nft.redeem(id, perkId);
        vm.stopPrank();

        (bool ok, string memory reason) = nft.canRedeem(id, perkId);
        assertFalse(ok);
        assertEq(reason, "ALREADY_REDEEMED");
    }

    function test_redeem_claimTravelsWithToken() public {
        // A redeemed token transferred to a new owner cannot redeem the same perk again.
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 0);
        vm.prank(alice);
        nft.redeem(id, perkId);
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.AlreadyRedeemed.selector, perkId, id));
        nft.redeem(id, perkId);
    }

    function test_redeem_revertsForNonOwner() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 0);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.NotTokenOwner.selector, id));
        nft.redeem(id, perkId);
    }

    function test_redeem_approvedOperatorCannotRedeem() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 0);
        vm.prank(alice);
        nft.setApprovalForAll(mallory, true);
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.NotTokenOwner.selector, id));
        nft.redeem(id, perkId);
    }

    function test_redeem_revertsWhenMembershipExpired() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 0);
        vm.warp(block.timestamp + 365 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.MembershipExpired.selector, id));
        nft.redeem(id, perkId);
    }

    function test_redeem_revertsForIneligibleTier() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x02, 0); // Godbold only
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.TierNotEligible.selector, perkId, SOTOLERO));
        nft.redeem(id, perkId);
    }

    function test_redeem_respectsWindow() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint64 start = uint64(block.timestamp + 1 days);
        uint64 end = uint64(block.timestamp + 2 days);
        vm.prank(admin);
        uint256 perkId = nft.createPerk(0x01, start, end, 0, "");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.PerkNotOpen.selector, perkId));
        nft.redeem(id, perkId);

        vm.warp(start);
        vm.prank(alice);
        nft.redeem(id, perkId);

        uint256 id2 = _mintFor(bob, SOTOLERO);
        vm.warp(end + 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.PerkNotOpen.selector, perkId));
        nft.redeem(id2, perkId);
    }

    function test_redeem_respectsMaxClaims() public {
        uint256 a = _mintFor(alice, SOTOLERO);
        uint256 b = _mintFor(bob, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 1);
        vm.prank(alice);
        nft.redeem(a, perkId);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.PerkSoldOut.selector, perkId));
        nft.redeem(b, perkId);
    }

    function test_redeem_inactiveOrMissingPerk() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.PerkNotFound.selector, 0));
        nft.redeem(id, 0);

        uint256 perkId = _createPerk(0x01, 0);
        vm.prank(admin);
        nft.updatePerk(perkId, 0x01, 0, 0, 0, false, "");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MarfaSpiritMembership.PerkInactive.selector, perkId));
        nft.redeem(id, perkId);
    }

    function test_updatePerk_cannotSetCapBelowClaimed() public {
        uint256 a = _mintFor(alice, SOTOLERO);
        uint256 b = _mintFor(bob, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 0);
        vm.prank(alice);
        nft.redeem(a, perkId);
        vm.prank(bob);
        nft.redeem(b, perkId);
        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.InvalidSupply.selector);
        nft.updatePerk(perkId, 0x01, 0, 0, 1, true, "");
    }

    function test_redeem_revertsWhenPaused() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint256 perkId = _createPerk(0x01, 0);
        vm.prank(admin);
        nft.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.redeem(id, perkId);
    }

    function test_canRedeem_reasons() public {
        (bool ok, string memory reason) = nft.canRedeem(99, 0);
        assertFalse(ok);
        assertEq(reason, "TOKEN_NOT_FOUND");

        uint256 id = _mintFor(alice, SOTOLERO);
        (ok, reason) = nft.canRedeem(id, 0);
        assertEq(reason, "PERK_NOT_FOUND");

        vm.prank(admin);
        uint256 perkId = nft.createPerk(0x02, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 0, "");
        (ok, reason) = nft.canRedeem(id, perkId);
        assertEq(reason, "PERK_NOT_STARTED");
        vm.warp(block.timestamp + 3 days);
        (ok, reason) = nft.canRedeem(id, perkId);
        assertEq(reason, "PERK_ENDED");
    }

    // ------------------------------------------------------------------
    // Membership admin
    // ------------------------------------------------------------------

    function test_extendMembership() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        uint64 before = nft.membershipOf(id).expiresAt;
        vm.prank(admin);
        nft.extendMembership(id, 30 days);
        assertEq(nft.membershipOf(id).expiresAt, before + 30 days);

        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.InvalidDuration.selector);
        nft.extendMembership(id, 0);

        vm.prank(mallory);
        vm.expectRevert();
        nft.extendMembership(id, 1);
    }

    function test_setMembershipDuration() public {
        vm.prank(admin);
        nft.setMembershipDuration(30 days);
        uint256 id = _mintFor(alice, SOTOLERO);
        assertEq(nft.membershipOf(id).expiresAt, block.timestamp + 30 days);

        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.InvalidDuration.selector);
        nft.setMembershipDuration(0);
    }

    // ------------------------------------------------------------------
    // Metadata
    // ------------------------------------------------------------------

    function test_metadata_updateAndFreeze() public {
        _mintFor(alice, SOTOLERO);
        vm.startPrank(admin);
        nft.setBaseURI("ipfs://new/");
        nft.setContractURI("ipfs://contract.json");
        assertEq(nft.tokenURI(1), "ipfs://new/1");
        assertEq(nft.contractURI(), "ipfs://contract.json");

        nft.freezeMetadata();
        vm.expectRevert(MarfaSpiritMembership.MetadataIsFrozen.selector);
        nft.setBaseURI("ipfs://again/");
        vm.expectRevert(MarfaSpiritMembership.MetadataIsFrozen.selector);
        nft.setContractURI("x");
        vm.stopPrank();
    }

    function test_tokenURI_revertsForNonexistent() public {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        nft.tokenURI(1);
    }

    function test_tokensOfOwner() public {
        uint256 a = _mintFor(alice, SOTOLERO);
        uint256 b = _mintFor(alice, GODBOLD);
        _mintFor(bob, SOTOLERO);
        uint256[] memory ids = nft.tokensOfOwner(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], a);
        assertEq(ids[1], b);
        assertEq(nft.tokensOfOwner(mallory).length, 0);
    }

    // ------------------------------------------------------------------
    // Pause
    // ------------------------------------------------------------------

    function test_pause_blocksTransfers_andOnlyAdminUnpauses() public {
        uint256 id = _mintFor(alice, SOTOLERO);
        vm.prank(admin);
        nft.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        nft.transferFrom(alice, bob, id);

        vm.prank(mallory);
        vm.expectRevert();
        nft.unpause();

        vm.prank(admin);
        nft.unpause();
        vm.prank(alice);
        nft.transferFrom(alice, bob, id);
        assertEq(nft.ownerOf(id), bob);
    }

    function test_pause_onlyManager() public {
        vm.prank(mallory);
        vm.expectRevert();
        nft.pause();
    }

    // ------------------------------------------------------------------
    // Treasury
    // ------------------------------------------------------------------

    function test_withdraw_sendsToPayout() public {
        _mintFor(alice, SOTOLERO);
        _mintFor(bob, GODBOLD);
        uint256 expected = PRICE_0 + PRICE_1;

        vm.expectEmit(true, false, false, true);
        emit MarfaSpiritMembership.Withdrawn(payout, expected);
        vm.prank(admin);
        nft.withdraw();

        assertEq(payout.balance, expected);
        assertEq(address(nft).balance, 0);
    }

    function test_withdraw_onlyAdmin() public {
        _mintFor(alice, SOTOLERO);
        vm.prank(mallory);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, mallory, bytes32(0))
        );
        nft.withdraw();
    }

    function test_withdraw_revertsWhenEmpty() public {
        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.NothingToWithdraw.selector);
        nft.withdraw();
    }

    function test_withdraw_revertsWhenPayoutRejects() public {
        RejectingPayout bad = new RejectingPayout();
        vm.prank(admin);
        nft.setPayoutAddress(address(bad));
        _mintFor(alice, SOTOLERO);
        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.WithdrawFailed.selector);
        nft.withdraw();
    }

    function test_withdraw_reentrancyBlocked() public {
        // Even if the payout address is an admin-controlled contract that re-enters, the
        // nested call reverts and the outer withdraw fails closed.
        ReentrantPayout evil = new ReentrantPayout(nft);
        vm.startPrank(admin);
        nft.grantRole(DEFAULT_ADMIN_ROLE, address(evil));
        nft.setPayoutAddress(address(evil));
        vm.stopPrank();
        _mintFor(alice, SOTOLERO);

        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.WithdrawFailed.selector);
        nft.withdraw();
        assertEq(address(nft).balance, PRICE_0);
    }

    function test_withdraw_worksWhilePaused() public {
        _mintFor(alice, SOTOLERO);
        vm.startPrank(admin);
        nft.pause();
        nft.withdraw();
        vm.stopPrank();
        assertEq(payout.balance, PRICE_0);
    }

    function test_setPayoutAddress() public {
        vm.prank(admin);
        vm.expectRevert(MarfaSpiritMembership.ZeroAddress.selector);
        nft.setPayoutAddress(address(0));

        vm.prank(mallory);
        vm.expectRevert();
        nft.setPayoutAddress(mallory);

        vm.prank(admin);
        nft.setPayoutAddress(bob);
        assertEq(nft.payoutAddress(), bob);
    }

    function test_setDefaultRoyalty() public {
        vm.prank(admin);
        nft.setDefaultRoyalty(bob, 1000);
        (address r, uint256 amt) = nft.royaltyInfo(1, 1 ether);
        assertEq(r, bob);
        assertEq(amt, 0.1 ether);
    }

    // ------------------------------------------------------------------
    // Invariant-style sanity: total ETH held equals sum of accepted payments
    // ------------------------------------------------------------------

    function testFuzz_balanceMatchesPayments(uint8 sotoleroMints, uint8 godboldMints) public {
        sotoleroMints = uint8(bound(sotoleroMints, 0, 20));
        godboldMints = uint8(bound(godboldMints, 0, 10));
        uint256 expected;
        for (uint256 i = 0; i < sotoleroMints; i++) {
            address who = makeAddr(string.concat("s", vm.toString(i)));
            vm.deal(who, 1 ether);
            _mintFor(who, SOTOLERO);
            expected += PRICE_0;
        }
        for (uint256 i = 0; i < godboldMints; i++) {
            address who = makeAddr(string.concat("g", vm.toString(i)));
            vm.deal(who, 1 ether);
            _mintFor(who, GODBOLD);
            expected += PRICE_1;
        }
        assertEq(address(nft).balance, expected);
        assertEq(nft.totalSupply(), uint256(sotoleroMints) + godboldMints);
    }
}
