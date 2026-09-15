// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title Marfa Spirit Co. Membership
 * @notice ERC-721 membership pass for Marfa Spirit Co. Each token is a tiered, time-limited
 *         membership that entitles the holder to redeem perks (bottle allocations, merchandise,
 *         tasting-room events) published by the distillery.
 *
 * @dev Design notes
 *  - Minting is voucher-gated. Because perks deliver alcohol, a member must be age-verified before
 *    they can join. The off-chain backend performs verification and then signs an EIP-712
 *    `MintVoucher` with a key holding `SIGNER_ROLE`. There is deliberately no open public mint.
 *  - Memberships expire (`membershipDuration`, default 365 days) and can be renewed on-chain.
 *    Perks can only be redeemed while a membership is active.
 *  - Yearly tiers: a member may `rollover` — burn their current token and mint next year's tier in
 *    one transaction. The tier being entered declares which tiers it accepts (`rolloverFromMask`)
 *    and what the trade-in costs (`rolloverPrice`, 0 = the burn is the payment). No voucher is
 *    required because the burned token already proves the holder passed age verification.
 *  - Transfers are age-gated. A token can only be sent to a wallet in the on-chain verified
 *    registry (`isVerified`). Minting verifies the minter; anyone else (a buyer, a gift recipient)
 *    first submits a backend-signed `WalletVoucher`. Staff can revoke a wallet at any time.
 *  - Perks are created by `MANAGER_ROLE`. Redemption is recorded on-chain per (perk, token) so a
 *    perk can never be double-claimed. Physical fulfilment happens off-chain, keyed by the
 *    `PerkRedeemed` event.
 *  - Funds are never pushed to arbitrary addresses: `withdraw` sends the full balance to a
 *    fixed `payoutAddress` that only `DEFAULT_ADMIN_ROLE` can change.
 *  - Follows Checks-Effects-Interactions everywhere; `nonReentrant` guards every function that
 *    performs an external call (`_safeMint` and `withdraw`).
 *  - Uses custom errors instead of revert strings for gas and clearer client handling.
 */
contract MarfaSpiritMembership is
    ERC721,
    ERC721Enumerable,
    ERC2981,
    AccessControl,
    Pausable,
    ReentrancyGuard,
    EIP712
{
    using Strings for uint256;

    // ---------------------------------------------------------------------
    // Roles
    // ---------------------------------------------------------------------

    /// @notice Can manage tiers, perks, metadata URIs, and pause the contract.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @notice Keys allowed to sign `MintVoucher`s (held by the age-verification backend).
    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @dev Max number of tiers; tier eligibility for perks is a uint8 bitmask.
    uint8 public constant MAX_TIERS = 8;

    bytes32 public constant MINT_VOUCHER_TYPEHASH =
        keccak256("MintVoucher(address to,uint8 tierId,uint256 nonce,uint256 deadline)");

    /// @notice Signed off-chain after the recipient has been age-verified.
    struct MintVoucher {
        address to;
        uint8 tierId;
        uint256 nonce;
        uint256 deadline;
    }

    bytes32 public constant WALLET_VOUCHER_TYPEHASH =
        keccak256("WalletVoucher(address wallet,uint256 nonce,uint256 deadline)");

    /// @notice Signed off-chain after `wallet`'s owner has been age-verified; lets it receive tokens.
    struct WalletVoucher {
        address wallet;
        uint256 nonce;
        uint256 deadline;
    }

    /// @dev Packed into two storage slots (+ the string).
    struct Tier {
        uint96 mintPrice; // wei
        uint96 renewalPrice; // wei
        uint96 rolloverPrice; // wei, paid when entering this tier by burning an accepted tier's token
        uint32 maxSupply;
        uint32 minted;
        uint16 maxPerWallet;
        uint8 rolloverFromMask; // bit i set => a tier-i token may be burned to enter this tier
        bool active;
        string name;
    }

    /// @dev Packed into one storage slot (+ the string).
    struct Perk {
        uint64 startsAt;
        uint64 endsAt; // 0 = no end
        uint32 maxClaims; // 0 = unlimited
        uint32 claimed;
        uint8 tierMask; // bit i set => tier i may redeem
        bool active;
        string uri; // off-chain description (IPFS/HTTPS)
    }

    /// @dev Packed into one storage slot.
    struct Membership {
        uint8 tierId;
        uint64 expiresAt;
    }

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    Tier[] private _tiers;
    Perk[] private _perks;

    mapping(uint256 tokenId => Membership) private _memberships;
    /// @dev perkId => tokenId => claimed
    mapping(uint256 perkId => mapping(uint256 tokenId => bool)) private _perkClaimed;
    /// @notice Voucher nonces that have already been consumed.
    mapping(uint256 nonce => bool) public nonceUsed;
    /// @notice Number of tokens minted per wallet per tier (used for `maxPerWallet`).
    mapping(address wallet => mapping(uint8 tierId => uint256)) public mintedPerWallet;
    /// @notice Wallets that have passed age verification and may receive membership tokens.
    mapping(address wallet => bool) public isVerified;

    uint256 private _nextTokenId = 1;

    /// @notice Seconds a membership is valid for after mint / renewal.
    uint64 public membershipDuration = 365 days;
    /// @notice How long after expiry a token may still be traded in via `rollover`.
    uint64 public rolloverGracePeriod = 30 days;
    /// @notice Sole destination of `withdraw`.
    address public payoutAddress;

    string private _baseTokenURI;
    /// @notice Collection-level metadata (OpenSea `contractURI`).
    string public contractURI;
    /// @notice Once true, base/contract URIs can never change again.
    bool public metadataFrozen;

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event TierCreated(uint8 indexed tierId, string name, uint96 mintPrice, uint96 renewalPrice, uint32 maxSupply);
    event TierUpdated(uint8 indexed tierId, uint96 mintPrice, uint96 renewalPrice, uint32 maxSupply, uint16 maxPerWallet, bool active);
    event TierRolloverUpdated(uint8 indexed tierId, uint8 rolloverFromMask, uint96 rolloverPrice);
    event MembershipRolledOver(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        address indexed member,
        uint8 fromTierId,
        uint8 toTierId,
        uint64 expiresAt
    );
    event RolloverGracePeriodUpdated(uint64 gracePeriod);
    event WalletVerified(address indexed wallet, address indexed by);
    event WalletVerificationRevoked(address indexed wallet, address indexed by);
    event PerkCreated(uint256 indexed perkId, uint8 tierMask, uint64 startsAt, uint64 endsAt, uint32 maxClaims, string uri);
    event PerkUpdated(uint256 indexed perkId, uint8 tierMask, uint64 startsAt, uint64 endsAt, uint32 maxClaims, bool active, string uri);
    event MembershipMinted(uint256 indexed tokenId, address indexed to, uint8 indexed tierId, uint64 expiresAt, uint256 nonce);
    event MembershipRenewed(uint256 indexed tokenId, address indexed payer, uint64 expiresAt);
    event MembershipExtended(uint256 indexed tokenId, uint64 expiresAt);
    event PerkRedeemed(uint256 indexed perkId, uint256 indexed tokenId, address indexed member);
    event PayoutAddressUpdated(address indexed payoutAddress);
    event Withdrawn(address indexed to, uint256 amount);
    event MembershipDurationUpdated(uint64 duration);
    event BaseURIUpdated(string baseURI);
    event ContractURIUpdated(string contractURI);
    event MetadataFrozenForever();

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error InvalidTier(uint8 tierId);
    error MaxTiersReached();
    error TierInactive(uint8 tierId);
    error TierSoldOut(uint8 tierId);
    error WalletLimitReached(uint8 tierId);
    error InvalidSupply();
    error IncorrectPayment(uint256 expected, uint256 sent);
    error VoucherExpired(uint256 deadline);
    error VoucherAlreadyUsed(uint256 nonce);
    error InvalidVoucherSigner(address signer);
    error NotVoucherRecipient();
    error RecipientNotVerified(address to);
    error NotTokenOwner(uint256 tokenId);
    error MembershipExpired(uint256 tokenId);
    error RolloverNotAccepted(uint8 fromTierId, uint8 toTierId);
    error RolloverWindowClosed(uint256 tokenId);
    error PerkNotFound(uint256 perkId);
    error PerkInactive(uint256 perkId);
    error PerkNotOpen(uint256 perkId);
    error PerkSoldOut(uint256 perkId);
    error TierNotEligible(uint256 perkId, uint8 tierId);
    error AlreadyRedeemed(uint256 perkId, uint256 tokenId);
    error InvalidWindow();
    error InvalidTierMask();
    error InvalidDuration();
    error MetadataIsFrozen();
    error NothingToWithdraw();
    error WithdrawFailed();

    // ---------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------

    /**
     * @param admin           Receives DEFAULT_ADMIN_ROLE and MANAGER_ROLE (multisig recommended).
     * @param signer          Backend key that signs mint vouchers.
     * @param payout          Destination for `withdraw`.
     * @param baseURI         Token metadata base URI (tokenId appended).
     * @param royaltyReceiver ERC-2981 royalty receiver.
     * @param royaltyBps      ERC-2981 royalty in basis points (e.g. 500 = 5%).
     */
    constructor(
        address admin,
        address signer,
        address payout,
        string memory baseURI,
        address royaltyReceiver,
        uint96 royaltyBps
    ) ERC721("Marfa Spirit Co. Membership", "MSCM") EIP712("Marfa Spirit Co. Membership", "1") {
        if (admin == address(0) || signer == address(0) || payout == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);
        _grantRole(SIGNER_ROLE, signer);

        payoutAddress = payout;
        _baseTokenURI = baseURI;

        if (royaltyReceiver != address(0)) {
            _setDefaultRoyalty(royaltyReceiver, royaltyBps);
        }
    }

    // ---------------------------------------------------------------------
    // Member actions
    // ---------------------------------------------------------------------

    /**
     * @notice Mint a membership using a voucher signed by the age-verification backend.
     * @dev The caller must be the voucher recipient and send exactly the tier's mint price.
     *      State is fully updated before `_safeMint` (external call to the receiver).
     */
    function mint(MintVoucher calldata voucher, bytes calldata signature)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 tokenId)
    {
        // ----- Checks -----
        if (voucher.to != msg.sender) revert NotVoucherRecipient();
        if (block.timestamp > voucher.deadline) revert VoucherExpired(voucher.deadline);
        if (nonceUsed[voucher.nonce]) revert VoucherAlreadyUsed(voucher.nonce);

        address signer = ECDSA.recover(hashVoucher(voucher), signature);
        if (!hasRole(SIGNER_ROLE, signer)) revert InvalidVoucherSigner(signer);

        uint8 tierId = voucher.tierId;
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        Tier storage tier = _tiers[tierId];
        if (!tier.active) revert TierInactive(tierId);
        if (tier.minted >= tier.maxSupply) revert TierSoldOut(tierId);
        if (mintedPerWallet[msg.sender][tierId] >= tier.maxPerWallet) revert WalletLimitReached(tierId);
        if (msg.value != tier.mintPrice) revert IncorrectPayment(tier.mintPrice, msg.value);

        // ----- Effects -----
        nonceUsed[voucher.nonce] = true;
        tier.minted += 1;
        mintedPerWallet[msg.sender][tierId] += 1;

        tokenId = _nextTokenId++;
        uint64 expiresAt = uint64(block.timestamp) + membershipDuration;
        _memberships[tokenId] = Membership({tierId: tierId, expiresAt: expiresAt});

        // The voucher is only issued after age verification, so the minter is now a verified wallet.
        if (!isVerified[msg.sender]) {
            isVerified[msg.sender] = true;
            emit WalletVerified(msg.sender, signer);
        }

        emit MembershipMinted(tokenId, msg.sender, tierId, expiresAt, voucher.nonce);

        // ----- Interactions -----
        _safeMint(msg.sender, tokenId);
    }

    /**
     * @notice Register a wallet as age-verified so it can receive membership tokens (secondary
     *         purchases, gifts). The voucher is issued by the backend after verification.
     * @dev Anyone may submit the voucher on the wallet's behalf; the signature is what matters.
     */
    function verifyWallet(WalletVoucher calldata voucher, bytes calldata signature) external whenNotPaused {
        if (block.timestamp > voucher.deadline) revert VoucherExpired(voucher.deadline);
        if (nonceUsed[voucher.nonce]) revert VoucherAlreadyUsed(voucher.nonce);
        if (voucher.wallet == address(0)) revert ZeroAddress();

        address signer = ECDSA.recover(hashWalletVoucher(voucher), signature);
        if (!hasRole(SIGNER_ROLE, signer)) revert InvalidVoucherSigner(signer);

        nonceUsed[voucher.nonce] = true;
        isVerified[voucher.wallet] = true;
        emit WalletVerified(voucher.wallet, signer);
    }

    /**
     * @notice Renew a membership for another `membershipDuration`. Anyone may pay to renew any
     *         token (e.g. gifting). Expired memberships renew from now; active ones extend.
     */
    function renew(uint256 tokenId) external payable whenNotPaused {
        _requireOwned(tokenId);
        Membership storage m = _memberships[tokenId];
        Tier storage tier = _tiers[m.tierId];
        if (msg.value != tier.renewalPrice) revert IncorrectPayment(tier.renewalPrice, msg.value);

        uint64 base = m.expiresAt > block.timestamp ? m.expiresAt : uint64(block.timestamp);
        uint64 newExpiry = base + membershipDuration;
        m.expiresAt = newExpiry;

        emit MembershipRenewed(tokenId, msg.sender, newExpiry);
    }

    /**
     * @notice Trade in a membership for next year's tier: burns `tokenId` and mints a token of
     *         `toTierId` to the caller. `toTierId` must accept `tokenId`'s tier and the caller must
     *         send exactly `toTier.rolloverPrice` (often 0 — the burn is the payment).
     * @dev Unexpired time carries over: the new expiry is max(now, oldExpiry) + membershipDuration.
     *      Expired tokens may still be traded in for `rolloverGracePeriod` after expiry.
     */
    function rollover(uint256 tokenId, uint8 toTierId)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 newTokenId)
    {
        // ----- Checks -----
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        Membership memory old = _memberships[tokenId];
        if (block.timestamp > uint256(old.expiresAt) + rolloverGracePeriod) revert RolloverWindowClosed(tokenId);

        if (toTierId >= _tiers.length) revert InvalidTier(toTierId);
        Tier storage tier = _tiers[toTierId];
        if (!tier.active) revert TierInactive(toTierId);
        if (tier.rolloverFromMask & (uint8(1) << old.tierId) == 0) revert RolloverNotAccepted(old.tierId, toTierId);
        if (tier.minted >= tier.maxSupply) revert TierSoldOut(toTierId);
        if (mintedPerWallet[msg.sender][toTierId] >= tier.maxPerWallet) revert WalletLimitReached(toTierId);
        if (msg.value != tier.rolloverPrice) revert IncorrectPayment(tier.rolloverPrice, msg.value);

        // ----- Effects -----
        delete _memberships[tokenId];
        _burn(tokenId); // no external calls in ERC721._burn

        tier.minted += 1;
        mintedPerWallet[msg.sender][toTierId] += 1;

        newTokenId = _nextTokenId++;
        uint64 base = old.expiresAt > block.timestamp ? old.expiresAt : uint64(block.timestamp);
        uint64 expiresAt = base + membershipDuration;
        _memberships[newTokenId] = Membership({tierId: toTierId, expiresAt: expiresAt});

        emit MembershipRolledOver(tokenId, newTokenId, msg.sender, old.tierId, toTierId, expiresAt);

        // ----- Interactions -----
        _safeMint(msg.sender, newTokenId);
    }

    /**
     * @notice Redeem a perk with an active membership token. Each (perk, token) pair can be
     *         redeemed once. Emits `PerkRedeemed`, which the fulfilment backend listens for.
     */
    function redeem(uint256 tokenId, uint256 perkId) external whenNotPaused {
        // ----- Checks -----
        if (ownerOf(tokenId) != msg.sender) revert NotTokenOwner(tokenId);
        Membership storage m = _memberships[tokenId];
        if (m.expiresAt <= block.timestamp) revert MembershipExpired(tokenId);

        if (perkId >= _perks.length) revert PerkNotFound(perkId);
        Perk storage perk = _perks[perkId];
        if (!perk.active) revert PerkInactive(perkId);
        if (block.timestamp < perk.startsAt || (perk.endsAt != 0 && block.timestamp > perk.endsAt)) {
            revert PerkNotOpen(perkId);
        }
        if (perk.tierMask & (uint8(1) << m.tierId) == 0) revert TierNotEligible(perkId, m.tierId);
        if (_perkClaimed[perkId][tokenId]) revert AlreadyRedeemed(perkId, tokenId);
        if (perk.maxClaims != 0 && perk.claimed >= perk.maxClaims) revert PerkSoldOut(perkId);

        // ----- Effects -----
        _perkClaimed[perkId][tokenId] = true;
        perk.claimed += 1;

        emit PerkRedeemed(perkId, tokenId, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice EIP-712 digest for a voucher; the backend signs this and clients can pre-verify.
    function hashVoucher(MintVoucher calldata voucher) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(MINT_VOUCHER_TYPEHASH, voucher.to, voucher.tierId, voucher.nonce, voucher.deadline))
        );
    }

    /// @notice EIP-712 digest for a wallet-verification voucher.
    function hashWalletVoucher(WalletVoucher calldata voucher) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(WALLET_VOUCHER_TYPEHASH, voucher.wallet, voucher.nonce, voucher.deadline))
        );
    }

    function membershipOf(uint256 tokenId) external view returns (Membership memory) {
        _requireOwned(tokenId);
        return _memberships[tokenId];
    }

    function isActive(uint256 tokenId) public view returns (bool) {
        _requireOwned(tokenId);
        return _memberships[tokenId].expiresAt > block.timestamp;
    }

    function tierCount() external view returns (uint256) {
        return _tiers.length;
    }

    function getTier(uint8 tierId) external view returns (Tier memory) {
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        return _tiers[tierId];
    }

    function perkCount() external view returns (uint256) {
        return _perks.length;
    }

    function getPerk(uint256 perkId) external view returns (Perk memory) {
        if (perkId >= _perks.length) revert PerkNotFound(perkId);
        return _perks[perkId];
    }

    function hasRedeemed(uint256 perkId, uint256 tokenId) external view returns (bool) {
        return _perkClaimed[perkId][tokenId];
    }

    /**
     * @notice Non-reverting eligibility check for UIs.
     * @return ok      Whether `redeem(tokenId, perkId)` would succeed for `tokenId`'s owner right now.
     * @return reason  Empty when ok, otherwise a short machine-readable reason.
     */
    function canRedeem(uint256 tokenId, uint256 perkId) external view returns (bool ok, string memory reason) {
        if (_ownerOf(tokenId) == address(0)) return (false, "TOKEN_NOT_FOUND");
        if (perkId >= _perks.length) return (false, "PERK_NOT_FOUND");
        Membership storage m = _memberships[tokenId];
        Perk storage perk = _perks[perkId];
        if (m.expiresAt <= block.timestamp) return (false, "MEMBERSHIP_EXPIRED");
        if (!perk.active) return (false, "PERK_INACTIVE");
        if (block.timestamp < perk.startsAt) return (false, "PERK_NOT_STARTED");
        if (perk.endsAt != 0 && block.timestamp > perk.endsAt) return (false, "PERK_ENDED");
        if (perk.tierMask & (uint8(1) << m.tierId) == 0) return (false, "TIER_NOT_ELIGIBLE");
        if (_perkClaimed[perkId][tokenId]) return (false, "ALREADY_REDEEMED");
        if (perk.maxClaims != 0 && perk.claimed >= perk.maxClaims) return (false, "PERK_SOLD_OUT");
        return (true, "");
    }

    /**
     * @notice Non-reverting check of whether `tokenId`'s owner could `rollover` into `toTierId` now.
     */
    function canRollover(uint256 tokenId, uint8 toTierId) external view returns (bool ok, string memory reason) {
        address owner = _ownerOf(tokenId);
        if (owner == address(0)) return (false, "TOKEN_NOT_FOUND");
        if (toTierId >= _tiers.length) return (false, "TIER_NOT_FOUND");
        Membership storage m = _memberships[tokenId];
        Tier storage tier = _tiers[toTierId];
        if (block.timestamp > uint256(m.expiresAt) + rolloverGracePeriod) return (false, "ROLLOVER_WINDOW_CLOSED");
        if (!tier.active) return (false, "TIER_INACTIVE");
        if (tier.rolloverFromMask & (uint8(1) << m.tierId) == 0) return (false, "ROLLOVER_NOT_ACCEPTED");
        if (tier.minted >= tier.maxSupply) return (false, "TIER_SOLD_OUT");
        if (mintedPerWallet[owner][toTierId] >= tier.maxPerWallet) return (false, "WALLET_LIMIT_REACHED");
        if (!isVerified[owner]) return (false, "WALLET_NOT_VERIFIED");
        return (true, "");
    }

    /// @notice All token IDs held by `owner`. Intended for off-chain callers (unbounded loop).
    function tokensOfOwner(address owner) external view returns (uint256[] memory tokenIds) {
        uint256 n = balanceOf(owner);
        tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            tokenIds[i] = tokenOfOwnerByIndex(owner, i);
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory base = _baseURI();
        return bytes(base).length > 0 ? string.concat(base, tokenId.toString()) : "";
    }

    // ---------------------------------------------------------------------
    // Manager: tiers
    // ---------------------------------------------------------------------

    function createTier(
        string calldata name,
        uint96 mintPrice,
        uint96 renewalPrice,
        uint32 maxSupply,
        uint16 maxPerWallet,
        bool active
    ) external onlyRole(MANAGER_ROLE) returns (uint8 tierId) {
        if (_tiers.length >= MAX_TIERS) revert MaxTiersReached();
        if (maxSupply == 0 || maxPerWallet == 0) revert InvalidSupply();

        tierId = uint8(_tiers.length);
        _tiers.push(
            Tier({
                mintPrice: mintPrice,
                renewalPrice: renewalPrice,
                rolloverPrice: 0,
                maxSupply: maxSupply,
                minted: 0,
                maxPerWallet: maxPerWallet,
                rolloverFromMask: 0,
                active: active,
                name: name
            })
        );
        emit TierCreated(tierId, name, mintPrice, renewalPrice, maxSupply);
    }

    /**
     * @notice Configure which tiers may be burned to enter `tierId`, and at what price.
     * @param rolloverFromMask bit i set => tier i is accepted; 0 disables rollover into this tier.
     */
    function setTierRollover(uint8 tierId, uint8 rolloverFromMask, uint96 rolloverPrice)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        // Every accepted tier must exist, and a tier cannot roll into itself.
        if (rolloverFromMask >> _tiers.length != 0 || rolloverFromMask & (uint8(1) << tierId) != 0) {
            revert InvalidTierMask();
        }
        Tier storage tier = _tiers[tierId];
        tier.rolloverFromMask = rolloverFromMask;
        tier.rolloverPrice = rolloverPrice;
        emit TierRolloverUpdated(tierId, rolloverFromMask, rolloverPrice);
    }

    /// @dev `maxSupply` may be lowered but never below what has already been minted.
    function updateTier(
        uint8 tierId,
        uint96 mintPrice,
        uint96 renewalPrice,
        uint32 maxSupply,
        uint16 maxPerWallet,
        bool active
    ) external onlyRole(MANAGER_ROLE) {
        if (tierId >= _tiers.length) revert InvalidTier(tierId);
        Tier storage tier = _tiers[tierId];
        if (maxSupply < tier.minted || maxPerWallet == 0) revert InvalidSupply();

        tier.mintPrice = mintPrice;
        tier.renewalPrice = renewalPrice;
        tier.maxSupply = maxSupply;
        tier.maxPerWallet = maxPerWallet;
        tier.active = active;
        emit TierUpdated(tierId, mintPrice, renewalPrice, maxSupply, maxPerWallet, active);
    }

    // ---------------------------------------------------------------------
    // Manager: perks
    // ---------------------------------------------------------------------

    function createPerk(uint8 tierMask, uint64 startsAt, uint64 endsAt, uint32 maxClaims, string calldata uri)
        external
        onlyRole(MANAGER_ROLE)
        returns (uint256 perkId)
    {
        _validatePerkParams(tierMask, startsAt, endsAt);
        perkId = _perks.length;
        _perks.push(
            Perk({
                startsAt: startsAt,
                endsAt: endsAt,
                maxClaims: maxClaims,
                claimed: 0,
                tierMask: tierMask,
                active: true,
                uri: uri
            })
        );
        emit PerkCreated(perkId, tierMask, startsAt, endsAt, maxClaims, uri);
    }

    function updatePerk(
        uint256 perkId,
        uint8 tierMask,
        uint64 startsAt,
        uint64 endsAt,
        uint32 maxClaims,
        bool active,
        string calldata uri
    ) external onlyRole(MANAGER_ROLE) {
        if (perkId >= _perks.length) revert PerkNotFound(perkId);
        _validatePerkParams(tierMask, startsAt, endsAt);
        Perk storage perk = _perks[perkId];
        if (maxClaims != 0 && maxClaims < perk.claimed) revert InvalidSupply();

        perk.tierMask = tierMask;
        perk.startsAt = startsAt;
        perk.endsAt = endsAt;
        perk.maxClaims = maxClaims;
        perk.active = active;
        perk.uri = uri;
        emit PerkUpdated(perkId, tierMask, startsAt, endsAt, maxClaims, active, uri);
    }

    // ---------------------------------------------------------------------
    // Manager: memberships & metadata
    // ---------------------------------------------------------------------

    /// @notice Grant extra time to a membership (customer service, comps, event prizes).
    function extendMembership(uint256 tokenId, uint64 extraSeconds) external onlyRole(MANAGER_ROLE) {
        _requireOwned(tokenId);
        if (extraSeconds == 0) revert InvalidDuration();
        Membership storage m = _memberships[tokenId];
        uint64 base = m.expiresAt > block.timestamp ? m.expiresAt : uint64(block.timestamp);
        uint64 newExpiry = base + extraSeconds;
        m.expiresAt = newExpiry;
        emit MembershipExtended(tokenId, newExpiry);
    }

    function setMembershipDuration(uint64 duration) external onlyRole(MANAGER_ROLE) {
        if (duration == 0) revert InvalidDuration();
        membershipDuration = duration;
        emit MembershipDurationUpdated(duration);
    }

    /**
     * @notice Staff override of the verified registry: onboard a wallet verified in person, or revoke
     *         one (fraud, chargeback). A revoked wallet keeps its tokens but cannot receive more, and
     *         cannot `rollover` (the new token would be minted to an unverified wallet).
     */
    function setWalletVerified(address wallet, bool verified) external onlyRole(MANAGER_ROLE) {
        if (wallet == address(0)) revert ZeroAddress();
        isVerified[wallet] = verified;
        if (verified) emit WalletVerified(wallet, msg.sender);
        else emit WalletVerificationRevoked(wallet, msg.sender);
    }

    /// @notice Zero means a token must still be active to be traded in.
    function setRolloverGracePeriod(uint64 gracePeriod) external onlyRole(MANAGER_ROLE) {
        rolloverGracePeriod = gracePeriod;
        emit RolloverGracePeriodUpdated(gracePeriod);
    }

    function setBaseURI(string calldata baseURI) external onlyRole(MANAGER_ROLE) {
        if (metadataFrozen) revert MetadataIsFrozen();
        _baseTokenURI = baseURI;
        emit BaseURIUpdated(baseURI);
    }

    function setContractURI(string calldata uri) external onlyRole(MANAGER_ROLE) {
        if (metadataFrozen) revert MetadataIsFrozen();
        contractURI = uri;
        emit ContractURIUpdated(uri);
    }

    function pause() external onlyRole(MANAGER_ROLE) {
        _pause();
    }

    // ---------------------------------------------------------------------
    // Admin
    // ---------------------------------------------------------------------

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function freezeMetadata() external onlyRole(DEFAULT_ADMIN_ROLE) {
        metadataFrozen = true;
        emit MetadataFrozenForever();
    }

    function setPayoutAddress(address payout) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (payout == address(0)) revert ZeroAddress();
        payoutAddress = payout;
        emit PayoutAddressUpdated(payout);
    }

    function setDefaultRoyalty(address receiver, uint96 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setDefaultRoyalty(receiver, feeBps);
    }

    /// @notice Sweep the full balance to `payoutAddress`. Callable by admin even while paused.
    function withdraw() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToWithdraw();
        address to = payoutAddress;

        emit Withdrawn(to, amount);
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
    }

    // ---------------------------------------------------------------------
    // Internals & overrides
    // ---------------------------------------------------------------------

    function _validatePerkParams(uint8 tierMask, uint64 startsAt, uint64 endsAt) private view {
        if (tierMask == 0) revert InvalidTierMask();
        // Every set bit must correspond to an existing tier.
        if (tierMask >> _tiers.length != 0) revert InvalidTierMask();
        if (endsAt != 0 && endsAt <= startsAt) revert InvalidWindow();
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    /**
     * @dev Every mint and transfer must land in an age-verified wallet (burns are always allowed).
     *      Also blocked entirely while paused — emergency circuit breaker.
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable)
        whenNotPaused
        returns (address)
    {
        if (to != address(0) && !isVerified[to]) revert RecipientNotVerified(to);
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC2981, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
