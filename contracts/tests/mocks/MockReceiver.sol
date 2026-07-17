// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReceiverTemplate} from "../../src/ReceiverTemplate.sol";

/// @dev A concrete {ReceiverTemplate} that records the reports it processes.
contract MockReceiver is ReceiverTemplate {
    error ProcessReportFailed();

    uint256 public processCallCount;
    bytes public lastReport;
    bool public shouldRevert;

    constructor(address forwarder) ReceiverTemplate(forwarder) {}

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function _processReport(bytes calldata report) internal override {
        if (shouldRevert) revert ProcessReportFailed();

        processCallCount++;
        lastReport = report;
    }
}
