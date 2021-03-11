pragma solidity ^0.6.7;

import { GemJoinAbstract } from "./dss-interfaces/dss/DaiJoinAbstract.sol";
import { VatAbstract } from "./dss-interfaces/dss/VatAbstract.sol";
import { LibNote } from "./dss/lib.sol";

/// @title Collateral Flash Lending Module
/// @dev Allows anyone to sell fyDai to MakerDao at a price determined from a governance
/// controlled interest rate.
contract DssJoinLender is LibNote {

    // --- Auth ---
    mapping (address => uint256) public wards;
    function rely(address usr) external auth { wards[usr] = 1; emit Rely(usr); }
    function deny(address usr) external auth { wards[usr] = 0; emit Deny(usr); }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);

    // --- Data ---
    struct Ilk {
        bytes32 ilk;
        GemJoinAbstract gemJoin;
        uint256 fee;
    }

    VatAbstract immutable public vat;

    mapping (address => Ilk) public ilks; // Collaterals available for lending

    // --- Init ---
    constructor(address daiJoin_, address vow_) public {
        wards[msg.sender] = 1;
        emit Rely(msg.sender);
        vat = VatAbstract(address(daiJoin__.vat()));
    }

    // hope can be used to transfer control of the TLM vault to another contract
    // This can be used to upgrade the contract
    function hope(address usr) external note auth {
        vat.hope(usr);
    }
    function nope(address usr) external note auth {
        vat.nope(usr);
    }

    /// @dev Overflow-protected casting
    function toInt256(uint256 x) internal pure returns (int256) {
        require(x <= MAXINT256, "DssTlm/int256-overflow");
        return(int256(x));
    }
    /// @dev Overflow-protected x + y
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "DssTlm/add-overflow");
    }
    /// @dev Overflow-protected x * y
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    /// @dev Overflow-protected x * y in RAY units
    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / 1e27;
    }

    // --- Administration ---
    /// @dev Add a join to the Gem Flash Lending Module.
    function init(bytes32 ilk, address gemJoin, uint256 fee) external note auth {
        address token = address(GemJoinAbstract(gemJoin).gem());
        require(ilks[token].gemJoin == address(0), "DssGflm/ilk-already-init");
        ilks[token].ilk = ilk;
        ilks[token].gemJoin = gemJoin;
        ilks[token].fee = fee;

        // TODO: auth
    }

    function maxFlashLoan(
        address token
    ) external view returns (uint256) {
        GemJoinAbstract gemJoin = ilks[token].gemJoin;
        if (address(gemJoin) == address(0)) return 0;
        IERC20 gem = IERC20(gemJoin.gem());
        return gem.balanceOf(address(gemJoin));
    }

    function flashFee(
        address token,
        uint256 amount
    ) external view returns (uint256) {
        require(ilks[token].gemJoin != address(0), "DssGflm/unsupported-token");
        return rmul(amount, ilks[token].fee);
    }

    function flashLoan(
        IERC3156FlashBorrower receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        /**
         * 1. Slip the amount into the flash lender account
         * 2. Withdraw the amount through the Join
         * 3. Send the amount to the borrower
         * 4. Callback
         * 5. Recover the amount from the borrower
         * 6. Return the amount to the Join
         * 7. Slip the amount out of the flash lender account
         */
        GemJoinAbstract gemJoin = ilks[token].gemJoin;
        IERC20 gem = IERC20(gemJoin.gem());

        require (gem.balanceOf(address(gemJoin)) >= amount, "FlashLender: Not enough supply");

        vat.slip(ilks[token].ilk, address(this), int256(amount));
        gemJoin.exit(msg.sender, amount);

        uint256 _fee = rmul(amount, ilks[token].fee);
        require(
            receiver.onFlashLoan(msg.sender, token, amount, _fee, data) == CALLBACK_SUCCESS,
            "FlashLender: Callback failed"
        );

        gem.transferFrom(msg.sender, address(this), add(amount, fee));
        gemJoin.join(address(this), amount);
        vat.slip(ilks[token].ilk, address(this), -toInt256(amount));
        // Do something with the fee
    }
}