package changeset

import (
	"fmt"
	"math/big"
	"time"

	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	gethtypes "github.com/ethereum/go-ethereum/core/types"
	owner_helpers "github.com/smartcontractkit/ccip-owner-contracts/pkg/gethwrappers"
	"github.com/smartcontractkit/ccip-owner-contracts/pkg/proposal/mcms"
	"github.com/smartcontractkit/ccip-owner-contracts/pkg/proposal/timelock"

	"github.com/smartcontractkit/chainlink/deployment"
	"github.com/smartcontractkit/chainlink/deployment/common/proposalutils"
	"github.com/smartcontractkit/chainlink/deployment/common/types"
	"github.com/smartcontractkit/chainlink/v2/core/gethwrappers/shared/generated/burn_mint_erc677"
)

type TransferToMCMSWithTimelockConfig struct {
	ContractsByChain map[uint64][]common.Address
	// MinDelay is for the accept ownership proposal
	MinDelay time.Duration
}

type Ownable interface {
	Owner(opts *bind.CallOpts) (common.Address, error)
	TransferOwnership(opts *bind.TransactOpts, newOwner common.Address) (*gethtypes.Transaction, error)
	AcceptOwnership(opts *bind.TransactOpts) (*gethtypes.Transaction, error)
	Address() common.Address
}

func LoadOwnableContract(addr common.Address, client bind.ContractBackend) (common.Address, Ownable, error) {
	// Just using the ownership interface from here.
	c, err := burn_mint_erc677.NewBurnMintERC677(addr, client)
	if err != nil {
		return common.Address{}, nil, fmt.Errorf("failed to create contract: %v", err)
	}
	owner, err := c.Owner(nil)
	if err != nil {
		return common.Address{}, nil, fmt.Errorf("failed to get owner of contract: %v", err)
	}
	return owner, c, nil
}

func (t TransferToMCMSWithTimelockConfig) Validate(e deployment.Environment) error {
	for chainSelector, contracts := range t.ContractsByChain {
		for _, contract := range contracts {
			// Cannot transfer an unknown address.
			// Note this also assures non-zero addresses.
			if exists, err := deployment.AddressBookContains(e.ExistingAddresses, chainSelector, contract.String()); err != nil || !exists {
				if err != nil {
					return fmt.Errorf("failed to check address book: %v", err)
				}
				return fmt.Errorf("contract %s not found in address book", contract)
			}
			owner, _, err := LoadOwnableContract(contract, e.Chains[chainSelector].Client)
			if err != nil {
				return fmt.Errorf("failed to load ownable: %v", err)
			}
			if owner != e.Chains[chainSelector].DeployerKey.From {
				return fmt.Errorf("contract %s is not owned by the deployer key", contract)
			}
		}
		// If there is no timelock and mcms proposer on the chain, the transfer will fail.
		if _, err := deployment.SearchAddressBook(e.ExistingAddresses, chainSelector, types.RBACTimelock); err != nil {
			return fmt.Errorf("timelock not present on the chain %v", err)
		}
		if _, err := deployment.SearchAddressBook(e.ExistingAddresses, chainSelector, types.ProposerManyChainMultisig); err != nil {
			return fmt.Errorf("mcms proposer not present on the chain %v", err)
		}
	}

	return nil
}

var _ deployment.ChangeSet[TransferToMCMSWithTimelockConfig] = TransferToMCMSWithTimelock

// TransferToMCMSWithTimelock creates a changeset that transfers ownership of all the
// contracts in the provided configuration to the timelock on the chain and generates
// a corresponding accept ownership proposal to complete the transfer.
// It assumes that DeployMCMSWithTimelock has already been run s.t.
// the timelock and mcmses exist on the chain and that the proposed addresses to transfer ownership
// are currently owned by the deployer key.
func TransferToMCMSWithTimelock(
	e deployment.Environment,
	cfg TransferToMCMSWithTimelockConfig,
) (deployment.ChangesetOutput, error) {
	if err := cfg.Validate(e); err != nil {
		return deployment.ChangesetOutput{}, err
	}
	var batches []timelock.BatchChainOperation
	timelocksByChain := make(map[uint64]common.Address)
	proposersByChain := make(map[uint64]*owner_helpers.ManyChainMultiSig)
	for chainSelector, contracts := range cfg.ContractsByChain {
		// Already validated that the timelock/proposer exists.
		timelockAddr, _ := deployment.SearchAddressBook(e.ExistingAddresses, chainSelector, types.RBACTimelock)
		proposerAddr, _ := deployment.SearchAddressBook(e.ExistingAddresses, chainSelector, types.ProposerManyChainMultisig)
		timelocksByChain[chainSelector] = common.HexToAddress(timelockAddr)
		proposer, err := owner_helpers.NewManyChainMultiSig(common.HexToAddress(proposerAddr), e.Chains[chainSelector].Client)
		if err != nil {
			return deployment.ChangesetOutput{}, fmt.Errorf("failed to create proposer mcms: %v", err)
		}
		proposersByChain[chainSelector] = proposer

		var ops []mcms.Operation
		for _, contract := range contracts {
			// Just using the ownership interface.
			// Already validated is ownable.
			owner, c, _ := LoadOwnableContract(contract, e.Chains[chainSelector].Client)
			if owner.String() == timelockAddr {
				// Already owned by timelock.
				e.Logger.Infof("contract %s already owned by timelock", contract)
				continue
			}
			tx, err := c.TransferOwnership(e.Chains[chainSelector].DeployerKey, common.HexToAddress(timelockAddr))
			_, err = deployment.ConfirmIfNoError(e.Chains[chainSelector], tx, err)
			if err != nil {
				return deployment.ChangesetOutput{}, fmt.Errorf("failed to transfer ownership of contract %T: %v", contract, err)
			}
			tx, err = c.AcceptOwnership(deployment.SimTransactOpts())
			if err != nil {
				return deployment.ChangesetOutput{}, fmt.Errorf("failed to generate accept ownership calldata of %s: %w", contract, err)
			}
			ops = append(ops, mcms.Operation{
				To:    contract,
				Data:  tx.Data(),
				Value: big.NewInt(0),
			})
		}
		batches = append(batches, timelock.BatchChainOperation{
			ChainIdentifier: mcms.ChainIdentifier(chainSelector),
			Batch:           ops,
		})
	}
	proposal, err := proposalutils.BuildProposalFromBatches(
		timelocksByChain, proposersByChain, batches, "Transfer ownership to timelock", cfg.MinDelay)
	if err != nil {
		return deployment.ChangesetOutput{}, fmt.Errorf("failed to build proposal from batch: %w, batches: %+v", err, batches)
	}

	return deployment.ChangesetOutput{Proposals: []timelock.MCMSWithTimelockProposal{*proposal}}, nil
}