module invest_platform::marketplace {
    use std::error;
    use std::signer;
    use std::option;
    use aptos_std::smart_table;
    use aptos_std::smart_vector;
    use aptos_framework::aptos_account;
    use aptos_framework::coin;
    use aptos_framework::object::{Self, Object, ObjectCore};
    use invest_platform::platform::{Self, ClubRegistry};
    

    // Seed for creating the marketplace object
    const APP_OBJECT_SEED: vector<u8> = b"MARKETPLACE";
    // Error codes for missing listings and sellers
    const E_NO_LISTING: u64 = 1;
    const E_NO_SELLER: u64 = 2;
    const E_INVALIDE_PRICE: u64 =3;

    // Struct to represent the marketplace signer
    struct MarketplaceSigner has key {
       extend_ref: object::ExtendRef,
    }

    // Struct to store seller addresses
    struct Sellers has key {
        addresses: smart_vector::SmartVector<address>
    }

    // Struct for each listing, holding the item and seller information
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct Listing has key {
        object: object::Object<object::ObjectCore>, // The item being sold
        seller: address,
        delete_ref: object::DeleteRef, 
        extend_ref: object::ExtendRef, 
    }

    // Struct for fixed-price listings
    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct ListingPrice<phantom CoinType> has key {
        price: u64, // The price of the item
    }

    // Struct to track listings created by each seller
    struct SellerListings has key {
        listings: smart_vector::SmartVector<address> // Addresses of seller's listings
    }

    // Initialization function to set up the marketplace module
    fun init_module(deployer: &signer) {
        let constructor_ref = object::create_named_object(deployer, APP_OBJECT_SEED);
        let extend_ref = object::generate_extend_ref(&constructor_ref);
        let marketplace_signer = &object::generate_signer(&constructor_ref);
        move_to(marketplace_signer, MarketplaceSigner { extend_ref });
    }

    // Entry function to list an item for sale
    public entry fun list_item<CoinType>(
       seller: &signer, 
       object: Object<ObjectCore>, // The item to be listed
        registry: Object<ClubRegistry>,
       price: u64, 
    ) acquires SellerListings, Sellers, MarketplaceSigner, ClubRegistry{

        let member = smart_table::borrow(registry.members, member_addr);
        
        
        assert!(smart_table::contains(registry.members, member_addr) == signer::address_of(seller)), ENOT_OWNER);
        
       // Validate that the price is greater than zero
       assert!(price > 0, error::invalid_argument(E_INVALIDE_PRICE));
        
      // Call internal function to handle listing logic
      listing_item<CoinType>(seller, object, price);
    }

    // Entry function to purchase an item from a listing
    public entry fun purchase<CoinType>(
       purchaser: &signer, 
       object: object::Object<object::ObjectCore>, // The listing object
    ) acquires ListingPrice, Listing, SellerListings, Sellers {
       let listing_addr = object::object_address(&object);

       // Ensure the listing exists
       assert!(exists<Listing>(listing_addr), error::not_found(E_NO_LISTING));
       assert!(exists<ListingPrice<CoinType>>(listing_addr), error::not_found(E_NO_LISTING));

       // Retrieve the price from the price listing
       let ListingPrice { price } = move_from<ListingPrice<CoinType>>(listing_addr);

       // Withdraw the required coins from the purchaser
       let coins = coin::withdraw<CoinType>(purchaser, price);

       // Move the listing data into local variables
       let Listing { object, seller, delete_ref, extend_ref } = move_from<Listing>(listing_addr);
 
      // Transfer the object to the purchaser after state change to avoid reentrancy
      let obj_signer = object::generate_signer_for_extending(&extend_ref);
      object::transfer(&obj_signer, object, signer::address_of(purchaser));
      object::delete(delete_ref); // Clean up the listing object

      // Remove the listing from the seller's listings
      let seller_listings = borrow_global_mut<SellerListings>(seller);
      let (exist, idx) = smart_vector::index_of(&seller_listings.listings, &listing_addr);
      assert!(exist, error::not_found(E_NO_LISTING));
      smart_vector::remove(&mut seller_listings.listings, idx);

      // If the seller has no more listings, remove them from the global sellers list
      if (smart_vector::length(&seller_listings.listings) == 0) {
      let sellers = borrow_global_mut<Sellers>(get_marketplace_signer_addr());
      let (exist, idx) = smart_vector::index_of(&sellers.addresses, &seller);
      assert!(exist, error::not_found(E_NO_SELLER));
      smart_vector::remove(&mut sellers.addresses, idx);
      };

      // Deposit the coins into the seller's account
      aptos_account::deposit_coins(seller, coins);
      }

       // Internal function to handle the logic of listing an item for sale
       public(friend) fun listing_item<CoinType>(
          seller: &signer, 
          object: object::Object<object::ObjectCore>, // The item to be listed
          price: u64, // The price of the item
    ): object::Object<Listing> acquires SellerListings, Sellers, MarketplaceSigner {
        let constructor_ref = object::create_object(signer::address_of(seller));
        let transfer_ref = object::generate_transfer_ref(&constructor_ref);
        object::disable_ungated_transfer(&transfer_ref);
        let listing_signer = object::generate_signer(&constructor_ref);

        // Create the listing and fixed price structures
        let listing = Listing {
           object,
           seller: signer::address_of(seller),
           delete_ref: object::generate_delete_ref(&constructor_ref),
           extend_ref: object::generate_extend_ref(&constructor_ref),
        };
           
       let fixed_price_listing = ListingPrice<CoinType> { price };

       // Move the listing and price data to the listing signer
       move_to(&listing_signer, listing);
       move_to(&listing_signer, fixed_price_listing);
       object::transfer(seller, object, signer::address_of(&listing_signer)); // Transfer the item to the listing signer

       // Retrieve the listing object from constructor reference
       let listing_obj = object::object_from_constructor_ref(&constructor_ref);
           
       // Update the seller's listings
       update_seller_listings(seller, listing_obj);
           
       // Update the global sellers registry
       update_sellers_registry(signer::address_of(seller));

       listing_obj // Return the listing object
    }

       // Helper function to update the seller's listings
       fun update_seller_listings(seller: &signer, listing: object::Object<Listing>) acquires SellerListings {
       // Check if seller listings exist, create if not
       let seller_listings = if (exists<SellerListings>(signer::address_of(seller))) {
       borrow_global_mut<SellerListings>(signer::address_of(seller))
       } else {
       let new_listings = SellerListings {
       listings: smart_vector::new(),
    };
       move_to(seller, new_listings);
       borrow_global_mut<SellerListings>(signer::address_of(seller))
    };

       // Add the new listing to the seller's listings
       smart_vector::push_back(&mut seller_listings.listings, object::object_address(&listing));
    }

       // Helper function to update the global sellers registry
       fun update_sellers_registry(seller: address) acquires Sellers, MarketplaceSigner {
       // Check if sellers registry exists, create if not
       let sellers = if (exists<Sellers>(get_marketplace_signer_addr())) {
       borrow_global_mut<Sellers>(get_marketplace_signer_addr())
       } else {
       let new_sellers = Sellers {
       addresses: smart_vector::new(),
    };

       move_to(&get_marketplace_signer(get_marketplace_signer_addr()), new_sellers);
       borrow_global_mut<Sellers>(get_marketplace_signer_addr())
    };

       // Add the seller to the registry if not already present
       if (!smart_vector::contains(&sellers.addresses, &seller)) {
       smart_vector::push_back(&mut sellers.addresses, seller);
    }
    }

   // View functions

#[view]
public fun price<CoinType>(
object: object::Object<Listing>,
): option::Option<u64> acquires ListingPrice {
let listing_addr = object::object_address(&object);
if (exists<ListingPrice<CoinType>>(listing_addr)) {
let fixed_price = borrow_global<ListingPrice<CoinType>>(listing_addr);
option::some(fixed_price.price)
} else {
// This should just be an abort but the compiler errors.
assert!(false, error::not_found(E_NO_LISTING));
option::none()
}
}

#[view]
public fun listing(object: object::Object<Listing>): (object::Object<object::ObjectCore>, address) acquires Listing {
let listing = borrow_listing(object);
(listing.object, listing.seller)
}

#[view]
public fun get_seller_listings(seller: address): vector<address> acquires SellerListings {
if (exists<SellerListings>(seller)) {
smart_vector::to_vector(&borrow_global<SellerListings>(seller).listings)
} else {
vector[]
}
}

#[view]
public fun get_sellers(): vector<address> acquires Sellers {
if (exists<Sellers>(get_marketplace_signer_addr())) {
smart_vector::to_vector(&borrow_global<Sellers>(get_marketplace_signer_addr()).addresses)
} else {
vector[]
}
}

// Helper functions

fun get_marketplace_signer_addr(): address {
object::create_object_address(&@invest_platform, APP_OBJECT_SEED)
}

fun get_marketplace_signer(marketplace_signer_addr: address): signer acquires MarketplaceSigner {
object::generate_signer_for_extending(&borrow_global<MarketplaceSigner>(marketplace_signer_addr).extend_ref)
}

inline fun borrow_listing(object: object::Object<Listing>): &Listing acquires Listing {
let obj_addr = object::object_address(&object);
assert!(exists<Listing>(obj_addr), error::not_found(E_NO_LISTING));
borrow_global<Listing>(obj_addr)
}

}


