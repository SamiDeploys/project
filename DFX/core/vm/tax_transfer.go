// core/vm/tax_transfer.go
package vm

import (
    "github.com/ethereum/go-ethereum/common"
    "github.com/ethereum/go-ethereum/core/tracing"
    "github.com/ethereum/go-ethereum/params"
    "github.com/holiman/uint256"
)

// DyfusionTransfer applies a configurable (rate/100) tax on the native L1 token,
// unless the tax feature is disabled, the amount is zero, sender/recipient is
// the treasury, or the recipient is the block’s coinbase (miner reward).
func DyfusionTransfer(
    db StateDB,
    from common.Address,
    to common.Address,
    amount *uint256.Int,
    cfg *params.ChainConfig,
    coinbase common.Address,
) {
    // --- Fallback to vanilla transfer if no tax or ineligible ---
    if !cfg.TaxEnabled || amount.IsZero() ||
        from == cfg.TreasuryAddress ||
        to == cfg.TreasuryAddress ||
        to == coinbase {
        // Inline what Transfer(...) would do:
        db.SubBalance(from, amount, tracing.BalanceChangeTransfer)
        db.AddBalance(to,   amount, tracing.BalanceChangeTransfer)
        return
    }

    // --- Compute tax = amount * rate / 100 ---
    tax := new(uint256.Int).Mul(amount, uint256.NewInt(cfg.TaxRate))
    tax.Div(tax, uint256.NewInt(100))

    // Net after tax
    net := new(uint256.Int).Sub(amount, tax)

    // --- Ledger updates with tracing ---
    db.SubBalance(from,           amount, tracing.BalanceChangeTransfer)  // sender pays 100%
    db.AddBalance(to,             net,    tracing.BalanceChangeTransfer)  // recipient gets 95%
    db.AddBalance(cfg.TreasuryAddress, tax, tracing.BalanceChangeTransfer) // treasury gets 5%
}
