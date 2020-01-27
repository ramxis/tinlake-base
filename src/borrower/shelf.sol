// shelf.sol -- keeps track and owns NFTs
// Copyright (C) 2019 lucasvo

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.3;

import "ds-note/note.sol";
import "tinlake-math/math.sol";
import "tinlake-auth/auth.sol";
import { TitleOwned } from "tinlake-title/title.sol";

contract NFTLike {
    function ownerOf(uint256 tokenId) public returns (address owner);
    function transferFrom(address from, address to, uint256 tokenId) public;
}

contract TitleLike {
    function issue(address) public returns (uint);
    function close(uint) public;
    function ownerOf (uint) public returns (address);
}

contract TokenLike {
    uint public totalSupply;
    function balanceOf(address) public view returns (uint);
    function transferFrom(address,address,uint) public returns (bool);
    function approve(address, uint) public;
}

contract PileLike {
    uint public total;
    function debt(uint) public returns (uint);
    function accrue(uint) public;
    function incDebt(uint, uint) public;
    function decDebt(uint, uint) public;
}

contract CeilingLike {
    function borrow(uint loan, uint currencyAmount) public;
    function repay(uint loan, uint currencyAmount) public;
}

contract DistributorLike {
    function balance() public;
}

contract Shelf is DSNote, Auth, TitleOwned, Math {

    // --- Data ---
    TitleLike public title;
    CeilingLike public ceiling;
    PileLike public pile;
    TokenLike public currency;
    DistributorLike public distributor;

    struct Loan {
        address registry;
        uint256 tokenId;
    }

    mapping (uint => uint) public balances;
    mapping (uint => Loan) public shelf;
    mapping (bytes32 => uint) public nftlookup;

    uint public balance;
    address public lender;

    constructor(address currency_, address title_, address pile_, address ceiling_) TitleOwned(title_) public {
        wards[msg.sender] = 1;
        currency = TokenLike(currency_);
        title = TitleLike(title_);
        pile = PileLike(pile_);
        ceiling = CeilingLike(ceiling_);
    }

    function depend(bytes32 what, address addr) external auth {
        if (what == "lender") {
            currency.approve(lender, uint(0));
            currency.approve(addr, uint(-1));
            lender = addr;
        }
        else if (what == "token") { currency = TokenLike(addr); }
        else if (what == "title") { title = TitleLike(addr); }
        else if (what == "pile") { pile = PileLike(addr); }
        else if (what == "ceiling") { ceiling = CeilingLike(addr); }
        else if (what == "distributor") { distributor = DistributorLike(addr);}
        else revert();
    }

    function file(uint loan, address registry_, uint nft_) external auth {
        shelf[loan].registry = registry_;
        shelf[loan].tokenId = nft_;
    }

    function token(uint loan) public view returns (address registry, uint nft) {
        return (shelf[loan].registry, shelf[loan].tokenId);
    }

    // --- Shelf: Loan actions ---
    function issue(address registry_, uint token_) external returns (uint) {
        require(NFTLike(registry_).ownerOf(token_) == msg.sender, "nft-not-owned");
        bytes32 nft = keccak256(abi.encodePacked(registry_, token_));
        require(nftlookup[nft] == 0, "nft-in-use");
        uint loan = title.issue(msg.sender);
        nftlookup[nft] = loan;
        shelf[loan].registry = registry_;
        shelf[loan].tokenId = token_;

        return loan;
    }

    function close(uint loan) external {
        require(pile.debt(loan) == 0, "outstanding-debt");
        require(!nftLocked(loan));
        (address registry, uint tokenId) = token(loan);
        require(title.ownerOf(loan) == msg.sender || NFTLike(registry).ownerOf(tokenId) == msg.sender, "not loan or nft owner");
        title.close(loan);
        bytes32 nft = keccak256(abi.encodePacked(shelf[loan].registry, shelf[loan].tokenId));
        nftlookup[nft] = 0;
        resetLoanBalance(loan);
    }

    // --- Currency actions ---
    function balanceRequest() external view returns (bool, uint) {
        uint currencyBalance = currency.balanceOf(address(this));
        if (balance > currencyBalance) {
            return (true, safeSub(balance, currencyBalance));

        } else {
            return (false, safeSub(currencyBalance, balance));
        }
    }

    function borrow(uint loan, uint currencyAmount) external owner(loan) {
        require(nftLocked(loan), "nft-not-locked");
        pile.accrue(loan);
        ceiling.borrow(loan, currencyAmount);
        pile.incDebt(loan, currencyAmount);
        balances[loan] = safeAdd(balances[loan], currencyAmount);
        balance = safeAdd(balance, currencyAmount);
    }

    function withdraw(uint loan, uint currencyAmount, address usr) external owner(loan) note {
        require(nftLocked(loan), "nft-not-locked");
        require(currencyAmount <= balances[loan], "amount-too-high");
        distributor.balance();
        balances[loan] = safeSub(balances[loan], currencyAmount);
        balance = safeSub(balance, currencyAmount);
        require(currency.transferFrom(address(this), usr, currencyAmount), "currency-transfer-failed");
    }

    function repay(uint loan, uint currencyAmount) external owner(loan) note {
        require(nftLocked(loan), "nft-not-locked");
        require(balances[loan] == 0,"before repay loan needs to be withdrawn");
        _repay(loan, msg.sender, currencyAmount);
    }

    function recover(uint loan, address usr, uint currencyAmount) external auth {
        pile.accrue(loan);
        uint loanDebt = pile.debt(loan);

        require(currency.transferFrom(usr, address(this), currencyAmount), "currency-transfer-failed");

        ceiling.repay(loan, currencyAmount);
        pile.decDebt(loan, loanDebt);
        resetLoanBalance(loan);
        distributor.balance();
    }

    function _repay(uint loan, address usr, uint currencyAmount) internal {
        pile.accrue(loan);
        uint loanDebt = pile.debt(loan);
        // only repay max loan debt
        if (currencyAmount > loanDebt) {
            currencyAmount = loanDebt;
        }
        require(currency.transferFrom(usr, address(this), currencyAmount), "currency-transfer-failed");
        ceiling.repay(loan, currencyAmount);
        pile.decDebt(loan, currencyAmount);
        distributor.balance();
    }

    // --- NFT actions ---
    function lock(uint loan) external owner(loan) {
        NFTLike(shelf[loan].registry).transferFrom(msg.sender, address(this), shelf[loan].tokenId);
    }

    function unlock(uint loan) external owner(loan) {
        require(pile.debt(loan) == 0, "has-debt");
        NFTLike(shelf[loan].registry).transferFrom(address(this), msg.sender, shelf[loan].tokenId);
    }

    function nftLocked(uint loan) public returns (bool) {
        return NFTLike(shelf[loan].registry).ownerOf(shelf[loan].tokenId) == address(this);
    }

    function claim(uint loan, address usr) public auth {
        NFTLike(shelf[loan].registry).transferFrom(address(this), usr, shelf[loan].tokenId);
    }

    function resetLoanBalance(uint loan) internal {
        uint loanBalance = balances[loan];
        if (loanBalance  > 0) {
            balances[loan] = 0;
            balance = safeSub(balance, loanBalance);
        }
    }
}