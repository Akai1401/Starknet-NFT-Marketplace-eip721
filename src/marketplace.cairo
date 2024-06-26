use starknet::ContractAddress;
use starknet::class_hash::ClassHash;
use Marketplace::RoyaltyInfo;
use Marketplace::Listing;
use Marketplace::Offer;
use Marketplace::CollectionOffer;

#[starknet::interface]
trait IMarketplace<TContractState> {
    /////////////////
    // Read Method //
    /////////////////

    fn getMarketFeeEarned(self: @TContractState) -> u256;

    fn getRoyaltyFeeEarned(self: @TContractState) -> u256;

    fn getRoyaltyInfo(self: @TContractState, assetContract: ContractAddress) -> RoyaltyInfo;

    fn getMarketFee(self: @TContractState) -> u256;

    fn getOwner(self: @TContractState) -> ContractAddress;

    fn getListingStatus(self: @TContractState, messageHash: felt252) -> felt252;

    fn getOfferStatus(self: @TContractState, messageHash: felt252) -> felt252;

    fn getCollectionOfferStatus(self: @TContractState, messageHash: felt252) -> felt252;

    fn getCollectionOfferAcceptedQuantity(self: @TContractState, messageHash: felt252) -> u128;

    //////////////////
    // Write Method //
    //////////////////

    fn cancelListing(ref self: TContractState, listing: Listing, signature: Array<felt252>);

    fn buyFromListing(ref self: TContractState, listing: Listing, signature: Array<felt252>);

    fn cancelOffer(ref self: TContractState, offer: Offer, signature: Array<felt252>);

    fn acceptOffer(ref self: TContractState, offer: Offer, signature: Array<felt252>);

    fn cancelCollectionOffer(
        ref self: TContractState, collectionOffer: CollectionOffer, signature: Array<felt252>
    );

    fn acceptCollectionOffer(
        ref self: TContractState,
        collectionOffer: CollectionOffer,
        signature: Array<felt252>,
        tokenId: felt252
    );

    fn updateOwner(ref self: TContractState, newOwner: ContractAddress);

    fn updateMarketFee(ref self: TContractState, newFee: u256);

    fn claimMarketFee(ref self: TContractState, amountToClaim: u256);

    fn claimRoyaltyFee(ref self: TContractState, amountToClaim: u256);

    fn setRoyaltyInfo(
        ref self: TContractState,
        assetContract: ContractAddress,
        royaltyFee: u256,
        royaltyReceiver: ContractAddress
    );
}

#[starknet::interface]
trait IInternal<TContractState> {
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);
}

#[starknet::contract]
mod Marketplace {
    use core::traits::TryInto;
    use core::hash::{HashStateTrait, HashStateExTrait, Hash};
    use array::ArrayTrait;
    use starknet::ContractAddress;
    use starknet::class_hash::ClassHash;
    use starknet::SyscallResult;
    use starknet::SyscallResultTrait;
    use starknet::{get_contract_address, get_caller_address, get_tx_info};
    use openzeppelin::token::erc20::interface::{IERC20CamelDispatcher, IERC20CamelDispatcherTrait};
    use openzeppelin::token::erc721::interface::{
        IERC721CamelOnlyDispatcher, IERC721CamelOnlyDispatcherTrait
    };
    use openzeppelin::account::interface::{AccountABIDispatcher, AccountABIDispatcherTrait};
    use starknet::call_contract_syscall;
    use poseidon::PoseidonTrait;
    use pedersen::PedersenTrait;
    use zeroable::Zeroable;
    use box::BoxTrait;

    const LISTING_STATUS_CREATED: felt252 = 1;
    const LISTING_STATUS_COMPLETED: felt252 = 2;
    const LISTING_STATUS_CANCELLED: felt252 = 3;

    const OFFER_STATUS_CREATED: felt252 = 4;
    const OFFER_STATUS_COMPLETED: felt252 = 5;
    const OFFER_STATUS_CANCELLED: felt252 = 6;

    const COLLECTION_OFFER_STATUS_CREATED: felt252 = 7;
    const COLLECTION_OFFER_STATUS_COMPLETED: felt252 = 8;
    const COLLECTION_OFFER_STATUS_CANCELLED: felt252 = 9;

    const ETH_CONTRACT_ADDRESS: felt252 =
        0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7;

    const STARKNET_DOMAIN_TYPE_HASH: felt252 =
        selector!("StarkNetDomain(name:felt,version:felt,chainId:felt)");

    const LISTING_STRUCT_TYPE_HASH: felt252 =
        selector!(
            "Listing(listing_counter:felt,token_id:felt,price:felt,asset_contract:felt,seller:felt)"
        );

    const OFFER_STRUCT_TYPE_HASH: felt252 =
        selector!(
            "Offer(offer_counter:felt,token_id:felt,price:felt,asset_contract:felt,offeror:felt)"
        );

    const COLLECTION_OFFER_STRUCT_TYPE_HASH: felt252 =
        selector!(
            "CollectionOffer(collection_offer_counter:felt,quantity:felt,price:felt,asset_contract:felt,offeror:felt)"
        );

    const is_valid_signature: felt252 =
        0x28420862938116cb3bbdbedee07451ccc54d4e9412dbef71142ad1980a30941;

    const isValidSignature: felt252 =
        0x213dfe25e2ca309c4d615a09cfc95fdb2fc7dc73fbcad12c450fe93b1f2ff9e;

    mod Errors {
        const ERROR_NOT_OWNER: felt252 = 'not owner';
        const ERROR_CLASS_HASH_CANNOT_BE_ZERO: felt252 = 'class hash can not not be zero';
        const ERROR_BALANCE_OR_ALLOWANCE_NOT_ENOUGH: felt252 = 'balance or allowance not enough';
        const ERROR_NFT_NOT_APPROVED_FOR_ALL: felt252 = 'nft not approved for all';
        const ERROR_INVALID_SIGNATURE: felt252 = 'invalid signature';
        const ERROR_INVALID_INPUT_LENGTH: felt252 = 'invalid input length';
        const ERROR_OUT_OF_CANCEL_RANGE: felt252 = 'out of cancel range';
        const ERROR_OUT_OF_BUY_RANGE: felt252 = 'out of buy range';
        const ERROR_NFT_OWNER_IS_NOT_SELLER: felt252 = 'nft owner is not seller';
        const ERROR_LISTING_INVALID_LISTING_COUNTER: felt252 = 'invalid listing counter';
        const ERROR_LISTING_INVALID_TOKEN_ID: felt252 = 'invalid listing token id';
        const ERROR_LISTING_INVALID_PRICE: felt252 = 'invalid listing price';
        const ERROR_LISTING_INVALID_ASSET_CONTRACT: felt252 = 'invalid listing asset contract';
        const ERROR_LISTING_INVALID_SELLER: felt252 = 'invalid listing seller';
        const ERROR_BUYER_IS_SELLER: felt252 = 'buyer is seller';
        const ERROR_LISTING_NOT_AVAILABLE: felt252 = 'listing not available';
        const ERROR_CALLER_IS_NOT_SELLER: felt252 = 'caller is not seller';
        const ERROR_INVALID_OFFER_COUNTER: felt252 = 'invalid offer counter';
        const ERROR_OFFER_INVALID_TOKEN_ID: felt252 = 'invalid offer token id';
        const ERROR_OFFER_INVALID_PRICE: felt252 = 'invalid offer price';
        const ERROR_OFFER_INVALID_ASSET_CONTRACT: felt252 = 'invalid offer asset contract';
        const ERROR_OFFER_INVALID_OFFEROR: felt252 = 'invalid offer offeror';
        const ERROR_SELLER_IS_OFFEROR: felt252 = 'seller is offeror';
        const ERROR_CALLER_IS_NOT_OFFEROR: felt252 = 'caller is not offeror';
        const ERROR_OFFER_NOT_AVAILABLE: felt252 = 'offer not available';
        const ERROR_INVALID_COLLECTION_OFFER_COUNTER: felt252 = 'invalid co offer counter';
        const ERROR_COLLECTION_OFFER_INVALID_QUANTITY: felt252 = 'invalid co offer quantity';
        const ERROR_COLLECTION_OFFER_INVALID_PRICE: felt252 = 'invalid co offer price';
        const ERROR_COLLECTION_OFFER_INVALID_ASSET_CONTRACT: felt252 =
            'invalid co offer asset contract';
        const ERROR_COLLECTION_OFFER_INVALID_OFFEROR: felt252 = 'invalid co offer offeror';
        const ERROR_SELLER_IS_COLLECTION_OFFEROR: felt252 = 'seller is co offeror';
        const ERROR_CALLER_IS_NOT_COLLECTION_OFFEROR: felt252 = 'caller is not co offeror';
        const ERROR_COLLECTION_OFFER_NOT_AVAILABLE: felt252 = 'co offer not available';
        const ERROR_EXCEEDS_QUANTITY_COLLECTION_OFFERED: felt252 = 'exceeds quantity co offered';
    }

    #[derive(Copy, Drop, Serde, starknet::Store)]
    struct RoyaltyInfo {
        royalty_fee: u256,
        total_earned: u256,
        royalty_receiver: ContractAddress
    }

    #[derive(Copy, Drop, Serde, Hash)]
    struct Listing {
        listing_counter: felt252,
        token_id: felt252,
        price: felt252,
        asset_contract: ContractAddress,
        seller: ContractAddress,
    }

    #[derive(Copy, Drop, Serde, Hash)]
    struct Offer {
        offer_counter: felt252,
        token_id: felt252,
        price: felt252,
        asset_contract: ContractAddress,
        offeror: ContractAddress,
    }

    #[derive(Copy, Drop, Serde, Hash)]
    struct CollectionOffer {
        collection_offer_counter: felt252,
        quantity: felt252,
        price: felt252,
        asset_contract: ContractAddress,
        offeror: ContractAddress
    }

    #[derive(Copy, Drop, Hash)]
    struct StarknetDomain {
        name: felt252,
        version: felt252,
        chain_id: felt252,
    }

    trait IStructHash<T> {
        fn hash_struct(self: @T) -> felt252;
    }

    trait IOffchainMessageHash<T> {
        fn get_message_hash(self: @T) -> felt252;
    }

    #[derive(Drop, starknet::Event)]
    struct EventListingCancelled {
        listing: Listing,
        status: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct EventListingBought {
        listing: Listing,
        buyer: ContractAddress,
        status: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct EventOfferCancelled {
        offer: Offer,
        status: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct EventOfferAccepted {
        offer: Offer,
        seller: ContractAddress,
        status: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct EventCollectionOfferCancelled {
        collection_offer: CollectionOffer,
        status: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct EventCollectionOfferCompleted {
        collection_offer: CollectionOffer,
        status: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct EventCollectionOfferAccepted {
        collection_offer: CollectionOffer,
        seller: ContractAddress,
        token_id: u128,
        amount_accepted: u128,
        status: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct EventUpgraded {
        class_hash: ClassHash
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        EventListingCancelled: EventListingCancelled,
        EventListingBought: EventListingBought,
        EventOfferCancelled: EventOfferCancelled,
        EventOfferAccepted: EventOfferAccepted,
        EventCollectionOfferCancelled: EventCollectionOfferCancelled,
        EventCollectionOfferCompleted: EventCollectionOfferCompleted,
        EventCollectionOfferAccepted: EventCollectionOfferAccepted,
        EventUpgraded: EventUpgraded
    }

    #[storage]
    struct Storage {
        _owner: ContractAddress,
        market_fee: u256,
        market_fee_earned: u256,
        collection_royalty_info: LegacyMap<ContractAddress, RoyaltyInfo>,
        royalty_fee_earned: u256,
        listing_status: LegacyMap<felt252, felt252>,
        offer_status: LegacyMap<felt252, felt252>,
        collection_offer_status: LegacyMap<felt252, felt252>,
        collection_offer_accepted_quantity: LegacyMap<felt252, u128>,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        let marketFee = 20; // NFT Marketplace fee = 2%
        self._owner.write(owner);
        self.market_fee.write(marketFee);
    }

    fn checkERC20BalanceAndAllowance(
        ref self: ContractState, owner: ContractAddress, spender: ContractAddress, amount: u256
    ) -> bool {
        let ethContractAddress: ContractAddress = ETH_CONTRACT_ADDRESS.try_into().unwrap();
        let ownerBalance = IERC20CamelDispatcher { contract_address: ethContractAddress }
            .balanceOf(owner);
        let ownerAllowance = IERC20CamelDispatcher { contract_address: ethContractAddress }
            .allowance(owner, spender);
        if (ownerBalance >= amount && ownerAllowance >= amount) {
            return true;
        }
        return false;
    }

    // Calculate the amount after subtracting the marketplace fee and royalty fee
    fn calculateAmountAfterFee(
        ref self: ContractState, amount: u256, assetContract: ContractAddress
    ) -> u256 {
        amount
            - (amount * self.market_fee.read() / 1000)
            - (amount * self.collection_royalty_info.read(assetContract).royalty_fee / 1000)
    }

    #[abi(embed_v0)]
    impl MarketplaceImpl of super::IMarketplace<ContractState> {
        /////////////////
        // Read Method //
        /////////////////

        fn getMarketFeeEarned(self: @ContractState) -> u256 {
            self.market_fee_earned.read()
        }

        fn getRoyaltyFeeEarned(self: @ContractState) -> u256 {
            self.royalty_fee_earned.read()
        }

        fn getRoyaltyInfo(self: @ContractState, assetContract: ContractAddress) -> RoyaltyInfo {
            self.collection_royalty_info.read(assetContract)
        }

        fn getMarketFee(self: @ContractState) -> u256 {
            self.market_fee.read()
        }

        fn getOwner(self: @ContractState) -> ContractAddress {
            self._owner.read()
        }

        fn getListingStatus(self: @ContractState, messageHash: felt252) -> felt252 {
            self.listing_status.read(messageHash)
        }

        fn getOfferStatus(self: @ContractState, messageHash: felt252) -> felt252 {
            self.offer_status.read(messageHash)
        }

        fn getCollectionOfferStatus(self: @ContractState, messageHash: felt252) -> felt252 {
            self.collection_offer_status.read(messageHash)
        }

        fn getCollectionOfferAcceptedQuantity(
            self: @ContractState, messageHash: felt252
        ) -> u128 {
            self.collection_offer_accepted_quantity.read(messageHash)
        }

        //////////////////
        // Write Method //
        //////////////////

        fn cancelListing(ref self: ContractState, listing: Listing, signature: Array<felt252>) {
            let caller = get_caller_address();
            let seller = listing.seller;

            // Check caller is seller
            assert(caller == seller, Errors::ERROR_CALLER_IS_NOT_SELLER);

            // Check status
            let hashMsgFinal = listing.get_message_hash();
            let mut status = self.listing_status.read(hashMsgFinal);
            assert(
                status != LISTING_STATUS_COMPLETED && status != LISTING_STATUS_CANCELLED,
                Errors::ERROR_LISTING_NOT_AVAILABLE
            );

            let isValid = AccountABIDispatcher { contract_address: seller }
                .is_valid_signature(hashMsgFinal, signature);

            assert(isValid == starknet::VALIDATED || isValid == 1, Errors::ERROR_INVALID_SIGNATURE);

            // Update status
            status = LISTING_STATUS_CANCELLED;
            self.listing_status.write(hashMsgFinal, status);

            // Emit event
            self.emit(EventListingCancelled { listing: listing, status: status });
        }

        fn buyFromListing(ref self: ContractState, listing: Listing, signature: Array<felt252>) {
            let buyer = get_caller_address();
            let seller = listing.seller;
            let thisContractAddress = get_contract_address();
            let ethContractAddress: ContractAddress = ETH_CONTRACT_ADDRESS.try_into().unwrap();

            let listing_counter: u256 = listing.listing_counter.into();
            let token_id: u256 = listing.token_id.into();
            let price: u256 = listing.price.into();

            // Check params
            assert(listing_counter > 0, Errors::ERROR_LISTING_INVALID_LISTING_COUNTER);
            assert(token_id > 0, Errors::ERROR_LISTING_INVALID_TOKEN_ID);
            assert(price > 0, Errors::ERROR_LISTING_INVALID_PRICE);
            assert(
                listing.asset_contract.is_non_zero(), Errors::ERROR_LISTING_INVALID_ASSET_CONTRACT
            );
            assert(listing.seller.is_non_zero(), Errors::ERROR_LISTING_INVALID_SELLER);

            // Check buyer is not seller
            assert(buyer != seller, Errors::ERROR_BUYER_IS_SELLER);

            // Check ERC20 balance and allowance
            assert(
                checkERC20BalanceAndAllowance(
                    ref self, buyer, thisContractAddress, listing.price.into()
                ),
                Errors::ERROR_BALANCE_OR_ALLOWANCE_NOT_ENOUGH
            );

            // Check NFT approve
            assert(
                IERC721CamelOnlyDispatcher { contract_address: listing.asset_contract }
                    .isApprovedForAll(seller, thisContractAddress),
                Errors::ERROR_NFT_NOT_APPROVED_FOR_ALL
            );

            // Check the seller owns the nft
            assert(
                IERC721CamelOnlyDispatcher { contract_address: listing.asset_contract }
                    .ownerOf(listing.token_id.into()) == seller,
                Errors::ERROR_NFT_OWNER_IS_NOT_SELLER
            );

            // Check status
            let hashMsgFinal = listing.get_message_hash();
            let mut status = self.listing_status.read(hashMsgFinal);
            assert(
                status != LISTING_STATUS_COMPLETED && status != LISTING_STATUS_CANCELLED,
                Errors::ERROR_LISTING_NOT_AVAILABLE
            );

            let isValid = AccountABIDispatcher { contract_address: seller }
                .is_valid_signature(hashMsgFinal, signature);

            assert(isValid == starknet::VALIDATED || isValid == 1, Errors::ERROR_INVALID_SIGNATURE);

            // Transfer ETH from buyer to contract
            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transferFrom(buyer, thisContractAddress, listing.price.into());

            // Update status
            status = LISTING_STATUS_COMPLETED;
            self.listing_status.write(hashMsgFinal, status);

            // Transfer NFT from seller to buyer
            IERC721CamelOnlyDispatcher { contract_address: listing.asset_contract }
                .transferFrom(listing.seller, buyer, listing.token_id.into());

            // Transfer ETH from contract to seller
            let amountSellerReceive = calculateAmountAfterFee(
                ref self, listing.price.into(), listing.asset_contract
            );

            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transfer(seller, amountSellerReceive);

            // Update market fee earned
            self
                .market_fee_earned
                .write(
                    self.market_fee_earned.read()
                        + listing.price.into() * self.market_fee.read() / 1000
                );

            // Update royalty fee earned
            self
                .royalty_fee_earned
                .write(
                    self.royalty_fee_earned.read()
                        + listing.price.into()
                            * self.collection_royalty_info.read(listing.asset_contract).royalty_fee
                            / 1000
                );

            let mut royaltyInfo = self.collection_royalty_info.read(listing.asset_contract);
            royaltyInfo.total_earned += listing.price.into()
                * self.collection_royalty_info.read(listing.asset_contract).royalty_fee
                / 1000;
            self.collection_royalty_info.write(listing.asset_contract, royaltyInfo);

            // Emit event
            self.emit(EventListingBought { listing: listing, buyer: buyer, status: status });
        }

        fn cancelOffer(ref self: ContractState, offer: Offer, signature: Array<felt252>) {
            let caller = get_caller_address();
            let offeror = offer.offeror;

            // Check caller is offeror
            assert(caller == offeror, Errors::ERROR_CALLER_IS_NOT_OFFEROR);

            // Check status
            let hashMsgFinal = offer.get_message_hash();
            let mut status = self.offer_status.read(hashMsgFinal);
            assert(
                status != OFFER_STATUS_COMPLETED && status != OFFER_STATUS_CANCELLED,
                Errors::ERROR_OFFER_NOT_AVAILABLE
            );

            let isValid = AccountABIDispatcher { contract_address: offeror }
                .is_valid_signature(hashMsgFinal, signature);

            assert(isValid == starknet::VALIDATED || isValid == 1, Errors::ERROR_INVALID_SIGNATURE);

            // Update status
            status = OFFER_STATUS_CANCELLED;
            self.offer_status.write(hashMsgFinal, status);

            // Emit event
            self.emit(EventOfferCancelled { offer: offer, status: status });
        }

        fn acceptOffer(ref self: ContractState, offer: Offer, signature: Array<felt252>) {
            let seller = get_caller_address();
            let offeror = offer.offeror;
            let thisContractAddress = get_contract_address();
            let ethContractAddress: ContractAddress = ETH_CONTRACT_ADDRESS.try_into().unwrap();

            let offer_counter: u256 = offer.offer_counter.into();
            let token_id: u256 = offer.token_id.into();
            let price: u256 = offer.price.into();

            // Check params
            assert(offer_counter > 0, Errors::ERROR_INVALID_OFFER_COUNTER);
            assert(token_id > 0, Errors::ERROR_OFFER_INVALID_TOKEN_ID);
            assert(price > 0, Errors::ERROR_OFFER_INVALID_PRICE);
            assert(offer.asset_contract.is_non_zero(), Errors::ERROR_OFFER_INVALID_ASSET_CONTRACT);
            assert(offer.offeror.is_non_zero(), Errors::ERROR_OFFER_INVALID_OFFEROR);

            // Check seller is not offeror
            assert(seller != offeror, Errors::ERROR_SELLER_IS_OFFEROR);

            // Check NFT approve
            assert(
                IERC721CamelOnlyDispatcher { contract_address: offer.asset_contract }
                    .isApprovedForAll(seller, thisContractAddress),
                Errors::ERROR_NFT_NOT_APPROVED_FOR_ALL
            );

            // Check the seller owns the nft
            assert(
                IERC721CamelOnlyDispatcher { contract_address: offer.asset_contract }
                    .ownerOf(offer.token_id.into()) == seller,
                Errors::ERROR_NFT_OWNER_IS_NOT_SELLER
            );

            // Check ERC20 balance and allowance
            assert(
                checkERC20BalanceAndAllowance(
                    ref self, offeror, thisContractAddress, offer.price.into()
                ),
                Errors::ERROR_BALANCE_OR_ALLOWANCE_NOT_ENOUGH
            );

            // Check status
            let hashMsgFinal = offer.get_message_hash();
            let mut status = self.offer_status.read(hashMsgFinal);
            assert(
                status != OFFER_STATUS_COMPLETED && status != OFFER_STATUS_CANCELLED,
                Errors::ERROR_OFFER_NOT_AVAILABLE
            );

            let isValid = AccountABIDispatcher { contract_address: offeror }
                .is_valid_signature(hashMsgFinal, signature);

            assert(isValid == starknet::VALIDATED || isValid == 1, Errors::ERROR_INVALID_SIGNATURE);

            // Transfer ETH from offeror to contract
            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transferFrom(offer.offeror, thisContractAddress, offer.price.into());

            // Update status
            status = OFFER_STATUS_COMPLETED;
            self.offer_status.write(hashMsgFinal, status);

            // Transfer NFT from seller to offeror
            IERC721CamelOnlyDispatcher { contract_address: offer.asset_contract }
                .transferFrom(seller, offeror, offer.token_id.into());

            // Transfer ETH from contract to seller
            let amountSellerReceive = calculateAmountAfterFee(
                ref self, offer.price.into(), offer.asset_contract
            );

            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transfer(seller, amountSellerReceive);

            // Update market fee earned
            self
                .market_fee_earned
                .write(
                    self.market_fee_earned.read()
                        + offer.price.into() * self.market_fee.read() / 1000
                );

            // Update royalty fee earned
            self
                .royalty_fee_earned
                .write(
                    self.royalty_fee_earned.read()
                        + offer.price.into()
                            * self.collection_royalty_info.read(offer.asset_contract).royalty_fee
                            / 1000
                );

            let mut royaltyInfo = self.collection_royalty_info.read(offer.asset_contract);
            royaltyInfo.total_earned += offer.price.into()
                * self.collection_royalty_info.read(offer.asset_contract).royalty_fee
                / 1000;
            self.collection_royalty_info.write(offer.asset_contract, royaltyInfo);

            // Emit event
            self.emit(EventOfferAccepted { offer: offer, seller: seller, status: status });
        }

        fn cancelCollectionOffer(
            ref self: ContractState, collectionOffer: CollectionOffer, signature: Array<felt252>
        ) {
            let caller = get_caller_address();
            let offeror = collectionOffer.offeror;

            // Check caller is offeror
            assert(caller == offeror, Errors::ERROR_CALLER_IS_NOT_COLLECTION_OFFEROR);

            // Check status
            let hashMsgFinal = collectionOffer.get_message_hash();
            let mut status = self.collection_offer_status.read(hashMsgFinal);
            assert(
                status != COLLECTION_OFFER_STATUS_COMPLETED
                    && status != COLLECTION_OFFER_STATUS_CANCELLED,
                Errors::ERROR_COLLECTION_OFFER_NOT_AVAILABLE
            );

            let isValid = AccountABIDispatcher { contract_address: offeror }
                .is_valid_signature(hashMsgFinal, signature);

            assert(isValid == starknet::VALIDATED || isValid == 1, Errors::ERROR_INVALID_SIGNATURE);

            // Update status
            status = COLLECTION_OFFER_STATUS_CANCELLED;
            self.collection_offer_status.write(hashMsgFinal, status);

            // Emit event
            self
                .emit(
                    EventCollectionOfferCancelled {
                        collection_offer: collectionOffer, status: status
                    }
                );
        }

        fn acceptCollectionOffer(
            ref self: ContractState,
            collectionOffer: CollectionOffer,
            signature: Array<felt252>,
            tokenId: felt252
        ) {
            let seller = get_caller_address();
            let offeror = collectionOffer.offeror;
            let thisContractAddress = get_contract_address();
            let ethContractAddress: ContractAddress = ETH_CONTRACT_ADDRESS.try_into().unwrap();

            let collection_offer_counter: u256 = collectionOffer.collection_offer_counter.into();
            let quantity: u256 = collectionOffer.quantity.into();
            let price: u256 = collectionOffer.price.into();

            // Check params
            assert(collection_offer_counter > 0, Errors::ERROR_INVALID_COLLECTION_OFFER_COUNTER);
            assert(quantity > 0, Errors::ERROR_COLLECTION_OFFER_INVALID_QUANTITY);
            assert(price > 0, Errors::ERROR_COLLECTION_OFFER_INVALID_PRICE);
            assert(
                collectionOffer.asset_contract.is_non_zero(),
                Errors::ERROR_COLLECTION_OFFER_INVALID_ASSET_CONTRACT
            );
            assert(
                collectionOffer.offeror.is_non_zero(),
                Errors::ERROR_COLLECTION_OFFER_INVALID_OFFEROR
            );

            // Check seller is not offeror
            assert(seller != offeror, Errors::ERROR_SELLER_IS_COLLECTION_OFFEROR);

            // Check collection offer amount status
            let hashMsgFinal = collectionOffer.get_message_hash();
            let quantityAccepted: u256 = self
                .collection_offer_accepted_quantity
                .read(hashMsgFinal)
                .into();
            assert(
                quantityAccepted + 1 <= quantity, Errors::ERROR_EXCEEDS_QUANTITY_COLLECTION_OFFERED
            );

            // Check NFT approve
            assert(
                IERC721CamelOnlyDispatcher { contract_address: collectionOffer.asset_contract }
                    .isApprovedForAll(seller, thisContractAddress),
                Errors::ERROR_NFT_NOT_APPROVED_FOR_ALL
            );

            // Check the seller owns the nft
            assert(
                IERC721CamelOnlyDispatcher { contract_address: collectionOffer.asset_contract }
                    .ownerOf(tokenId.into()) == seller,
                Errors::ERROR_NFT_OWNER_IS_NOT_SELLER
            );

            // Check ERC20 balance and allowance
            assert(
                checkERC20BalanceAndAllowance(
                    ref self, offeror, thisContractAddress, collectionOffer.price.into()
                ),
                Errors::ERROR_BALANCE_OR_ALLOWANCE_NOT_ENOUGH
            );

            // Check status
            let mut status = self.collection_offer_status.read(hashMsgFinal);
            assert(
                status != COLLECTION_OFFER_STATUS_COMPLETED
                    && status != COLLECTION_OFFER_STATUS_CANCELLED,
                Errors::ERROR_COLLECTION_OFFER_NOT_AVAILABLE
            );

            let isValid = AccountABIDispatcher { contract_address: offeror }
                .is_valid_signature(hashMsgFinal, signature);

            assert(isValid == starknet::VALIDATED || isValid == 1, Errors::ERROR_INVALID_SIGNATURE);

            // Transfer ETH from offeror to contract
            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transferFrom(
                    collectionOffer.offeror, thisContractAddress, collectionOffer.price.into()
                );

            // Update offer quantity, token_id & status
            let finalQuantity = quantityAccepted + 1;
            if (finalQuantity == quantity) {
                status = COLLECTION_OFFER_STATUS_COMPLETED;
                self.collection_offer_status.write(hashMsgFinal, status);
                self
                    .emit(
                        EventCollectionOfferCompleted {
                            collection_offer: collectionOffer, status: status
                        }
                    )
            }
            self
                .collection_offer_accepted_quantity
                .write(hashMsgFinal, finalQuantity.try_into().unwrap());

            // Transfer NFT from seller to offeror
            IERC721CamelOnlyDispatcher { contract_address: collectionOffer.asset_contract }
                .transferFrom(seller, offeror, tokenId.into());

            // Transfer ETH from contract to seller
            let amountSellerReceive = calculateAmountAfterFee(
                ref self, collectionOffer.price.into(), collectionOffer.asset_contract
            );

            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transfer(seller, amountSellerReceive);

            // Update market fee earned
            self
                .market_fee_earned
                .write(
                    self.market_fee_earned.read()
                        + collectionOffer.price.into() * self.market_fee.read() / 1000
                );

            // Update royalty fee earned
            self
                .royalty_fee_earned
                .write(
                    self.royalty_fee_earned.read()
                        + collectionOffer.price.into()
                            * self
                                .collection_royalty_info
                                .read(collectionOffer.asset_contract)
                                .royalty_fee
                            / 1000
                );

            let mut royaltyInfo = self.collection_royalty_info.read(collectionOffer.asset_contract);
            royaltyInfo.total_earned += collectionOffer.price.into()
                * self.collection_royalty_info.read(collectionOffer.asset_contract).royalty_fee
                / 1000;
            self.collection_royalty_info.write(collectionOffer.asset_contract, royaltyInfo);

            // Emit event
            self
                .emit(
                    EventCollectionOfferAccepted {
                        collection_offer: collectionOffer,
                        seller: seller,
                        token_id: tokenId.try_into().unwrap(),
                        amount_accepted: finalQuantity.try_into().unwrap(),
                        status: status
                    }
                );
        }

        fn updateOwner(ref self: ContractState, newOwner: ContractAddress) {
            let caller = get_caller_address();

            // Check owner
            assert(caller == self._owner.read(), Errors::ERROR_NOT_OWNER);

            // Update owner
            self._owner.write(newOwner);
        }

        fn updateMarketFee(ref self: ContractState, newFee: u256) {
            let caller = get_caller_address();

            // Check owner
            assert(caller == self._owner.read(), Errors::ERROR_NOT_OWNER);

            // Update market fee
            self.market_fee.write(newFee);
        }

        fn claimMarketFee(ref self: ContractState, amountToClaim: u256) {
            let caller = get_caller_address();
            let ethContractAddress: ContractAddress = ETH_CONTRACT_ADDRESS.try_into().unwrap();

            // Check owner
            assert(caller == self._owner.read(), Errors::ERROR_NOT_OWNER);

            // Transfer fee to caller
            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transfer(caller, amountToClaim);

            // Update fee earned
            self.market_fee_earned.write(self.market_fee_earned.read() - amountToClaim);
        }

        fn claimRoyaltyFee(ref self: ContractState, amountToClaim: u256) {
            let caller = get_caller_address();
            let ethContractAddress: ContractAddress = ETH_CONTRACT_ADDRESS.try_into().unwrap();

            // Check owner
            assert(caller == self._owner.read(), Errors::ERROR_NOT_OWNER);

            // Transfer fee to caller
            IERC20CamelDispatcher { contract_address: ethContractAddress }
                .transfer(caller, amountToClaim);

            // Update fee earned
            self.royalty_fee_earned.write(self.royalty_fee_earned.read() - amountToClaim);
        }

        fn setRoyaltyInfo(
            ref self: ContractState,
            assetContract: ContractAddress,
            royaltyFee: u256,
            royaltyReceiver: ContractAddress
        ) {
            let caller = get_caller_address();

            // Check owner
            assert(caller == self._owner.read(), Errors::ERROR_NOT_OWNER);

            // Set Royalty Info
            let mut royaltyInfoData = self.collection_royalty_info.read(assetContract);
            royaltyInfoData.royalty_fee = royaltyFee;
            royaltyInfoData.royalty_receiver = royaltyReceiver;
            self.collection_royalty_info.write(assetContract, royaltyInfoData);
        }
    }

    impl OffchainMessageHashListing of IOffchainMessageHash<Listing> {
        fn get_message_hash(self: @Listing) -> felt252 {
            let domain = StarknetDomain {
                name: 'Marketplace', version: 1, chain_id: get_tx_info().unbox().chain_id
            };
            let mut hashState = PedersenTrait::new(0);
            hashState = hashState.update_with('StarkNet Message');
            hashState = hashState.update_with(domain.hash_struct());
            hashState = hashState.update_with(*self.seller);
            hashState = hashState.update_with(self.hash_struct());
            hashState = hashState.update_with(4);
            hashState.finalize()
        }
    }

    impl OffchainMessageHashOffer of IOffchainMessageHash<Offer> {
        fn get_message_hash(self: @Offer) -> felt252 {
            let domain = StarknetDomain {
                name: 'Marketplace', version: 1, chain_id: get_tx_info().unbox().chain_id
            };
            let mut hashState = PedersenTrait::new(0);
            hashState = hashState.update_with('StarkNet Message');
            hashState = hashState.update_with(domain.hash_struct());
            hashState = hashState.update_with(*self.offeror);
            hashState = hashState.update_with(self.hash_struct());
            hashState = hashState.update_with(4);
            hashState.finalize()
        }
    }

    impl OffchainMessageHashCollectionOffer of IOffchainMessageHash<CollectionOffer> {
        fn get_message_hash(self: @CollectionOffer) -> felt252 {
            let domain = StarknetDomain {
                name: 'Marketplace', version: 1, chain_id: get_tx_info().unbox().chain_id
            };
            let mut hashState = PedersenTrait::new(0);
            hashState = hashState.update_with('StarkNet Message');
            hashState = hashState.update_with(domain.hash_struct());
            hashState = hashState.update_with(*self.offeror);
            hashState = hashState.update_with(self.hash_struct());
            hashState = hashState.update_with(4);
            hashState.finalize()
        }
    }

    impl StructHashStarknetDomain of IStructHash<StarknetDomain> {
        fn hash_struct(self: @StarknetDomain) -> felt252 {
            let mut hashState = PedersenTrait::new(0);
            hashState = hashState.update_with(STARKNET_DOMAIN_TYPE_HASH);
            hashState = hashState.update_with(*self);
            hashState = hashState.update_with(4);
            hashState.finalize()
        }
    }


    impl StructHashListing of IStructHash<Listing> {
        fn hash_struct(self: @Listing) -> felt252 {
            let mut hashState = PedersenTrait::new(0);
            hashState = hashState.update_with(LISTING_STRUCT_TYPE_HASH);
            hashState = hashState.update_with(*self);
            hashState = hashState.update_with(6);
            hashState.finalize()
        }
    }

    impl StructHashOffer of IStructHash<Offer> {
        fn hash_struct(self: @Offer) -> felt252 {
            let mut hashState = PedersenTrait::new(0);
            hashState = hashState.update_with(OFFER_STRUCT_TYPE_HASH);
            hashState = hashState.update_with(*self);
            hashState = hashState.update_with(6);
            hashState.finalize()
        }
    }

    impl StructHashCollectionOffer of IStructHash<CollectionOffer> {
        fn hash_struct(self: @CollectionOffer) -> felt252 {
            let mut hashState = PedersenTrait::new(0);
            hashState = hashState.update_with(COLLECTION_OFFER_STRUCT_TYPE_HASH);
            hashState = hashState.update_with(*self);
            hashState = hashState.update_with(6);
            hashState.finalize()
        }
    }

    #[abi(embed_v0)]
    impl InternalImpl of super::IInternal<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            // Check owner
            let caller = get_caller_address();
            assert(caller == self._owner.read(), Errors::ERROR_NOT_OWNER);

            // Check class hash
            assert(!new_class_hash.is_zero(), Errors::ERROR_CLASS_HASH_CANNOT_BE_ZERO);

            // Upgrade
            starknet::replace_class_syscall(new_class_hash).unwrap_syscall();
            self.emit(EventUpgraded { class_hash: new_class_hash });
        }
    }
}
