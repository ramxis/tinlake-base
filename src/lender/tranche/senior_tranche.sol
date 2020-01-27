// Copyright (C) 2020 Centrifuge
//
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

pragma solidity >=0.5.12;

import "./tranche.sol";
import "tinlake-math/interest.sol";

contract AssessorLike {
    function accrueTrancheInterest(address tranche_) public returns (uint);
}

// SeniorTranche
// Interface to the senior tranche. keeps track of the current debt towards the tranche.
contract SeniorTranche is Tranche, Interest {

    uint public ratePerSecond;      // interest rate per second in RAD (10^27)
    uint public lastUpdated;        // Last time the accumlated rate has been updated

    uint public borrowed;
    uint public interest;

    AssessorLike  public assessor;

    function debt() public returns(uint) {
        drip();
        return safeAdd(borrowed, interest);
    }

    constructor(address token_, address currency_, address assessor_) Tranche(token_ ,currency_) public {
        ratePerSecond = ONE;
        lastUpdated = now;
        assessor = AssessorLike(assessor_);
    }

    function depend(bytes32 what, address addr) public note auth {
        if (what == "assessor") {assessor = AssessorLike(addr); }
        else { super.depend(what, addr); }
    }

    function file(bytes32 what, uint ratePerSecond_) public note auth {
         if (what ==  "rate") {
            drip();
            ratePerSecond = ratePerSecond_;
        }
    }


    function _repay(uint currencyAmount) internal {
        if(currencyAmount <= interest) {
            interest = safeSub(interest, currencyAmount);
            return;
        }

        currencyAmount = safeSub(currencyAmount, interest);
        interest = 0;

        if (currencyAmount <= borrowed){
            borrowed = safeSub(borrowed, currencyAmount);
            return;
        }
        borrowed = 0;
    }
    function repay(address usr, uint currencyAmount) public note auth {
        drip();
        _repay(currencyAmount);
        super.repay(usr, currencyAmount);
    }

    function borrow(address usr, uint currencyAmount) public note auth {
        drip();
        borrowed = safeAdd(borrowed, currencyAmount);
        super.borrow(usr, currencyAmount);
    }

    function drip() public {
        if (now >= lastUpdated) {
            interest = safeAdd(interest, assessor.accrueTrancheInterest(address(this)));
            lastUpdated = now;
        }
    }
}
