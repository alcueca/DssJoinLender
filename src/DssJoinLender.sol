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

    function maxFlashLoan(
        address token
    ) external view returns (uint256);

    function flashFee(
        address token,
        uint256 amount
    ) external view returns (uint256);

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

        uint256 _fee = amount * ilks[token].fee / 1e27;
        require(
            receiver.onFlashLoan(msg.sender, token, amount, _fee, data) == CALLBACK_SUCCESS,
            "FlashLender: Callback failed"
        );

        gem.transferFrom(msg.sender, address(this), add(amount, fee));
        gemJoin.join(address(this), amount);
        vat.slip(ilks[token].ilk, address(this), -int256(amount));
        // Do something with the fee
    }
}