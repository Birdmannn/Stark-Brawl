use starknet::ContractAddress;
use core::num::traits::Zero;

#[starknet::interface]
pub trait IPlayerSystem<T> {
    fn initialize(ref self: T);
    // Combat
    fn take_damage(ref self: T, player_address: ContractAddress, amount: u16);
    fn heal(ref self: T, player_address: ContractAddress, amount: u16);
    fn is_alive(self: @T, player_address: ContractAddress) -> bool;
    // Currency
    fn add_coins(ref self: T, player_address: ContractAddress, amount: u64);
    fn spend_coins(ref self: T, player_address: ContractAddress, amount: u64);
    fn add_gems(ref self: T, player_address: ContractAddress, amount: u64);
    fn spend_gems(ref self: T, player_address: ContractAddress, amount: u64);
    // Equipment
    fn equip_ability(ref self: T, player_address: ContractAddress, ability_id: u256);
    fn activate_tower(ref self: T, player_address: ContractAddress);
    // Upgrades
    fn upgrade_max_hp(ref self: T, player_address: ContractAddress, value: u16);
    // --- Getters ---
    fn get_hp(self: @T, player_address: ContractAddress) -> u16;
    fn get_max_hp(self: @T, player_address: ContractAddress) -> u16;
    fn get_coins(self: @T, player_address: ContractAddress) -> u64;
    fn get_gems(self: @T, player_address: ContractAddress) -> u64;
    fn get_equipped_ability(self: @T, player_address: ContractAddress) -> u256;
    fn get_active_towers(self: @T, player_address: ContractAddress) -> u8;

    fn get_mana(self: @T, player_address: ContractAddress) -> u8;
    fn get_max_mana(self: @T, player_address: ContractAddress) -> u8;
    fn spend_mana(ref self: T, player_address: ContractAddress, amount: u8);
    fn regenerate_mana(ref self: T, player_address: ContractAddress, amount: u8);
    fn get_ability_cooldown(self: @T, player_address: ContractAddress, ability_id: u256) -> u64;
    fn set_ability_cooldown(
        ref self: T, player_address: ContractAddress, ability_id: u256, cooldown_until: u64,
    );
    fn has_ability_equipped(self: @T, player_address: ContractAddress, ability_id: u256) -> bool;
}

#[derive(Copy, Drop, Serde, Default, Introspect)]
pub enum PlayerStatus {
    Alive,
    Dead,
    InGame,
    #[default]
    Waiting,
}

#[derive(Copy, Drop, Serde, Default)]
#[dojo::model]
pub struct PlayerData {
    #[key]
    pub id: ContractAddress,
    pub hp: u16,
    pub max_hp: u16,
    pub coins: u64,
    pub gems: u64,
    pub equipped_ability: u256,
    pub active_towers: u8,
    pub mana: u8,
    pub max_mana: u8,
}

#[derive(Copy, Drop, Serde, Default)]
#[dojo::model]
pub struct AC {
    #[key]
    pub player: ContractAddress,
    #[key]
    pub ability_id: u256,
    pub ability_cooldown: u64,
}

impl ContractAddressDefault of Default<ContractAddress> {
    #[inline(always)]
    fn default() -> ContractAddress {
        Zero::zero()
    }
}

#[dojo::contract]
pub mod PlayerSystem {
    use starknet::{ContractAddress, get_caller_address};
    use super::IPlayerSystem;
    use crate::models::player::{Player, PlayerTrait};
    use super::PlayerData;
    use dojo::model::{Model, ModelStorage, ModelValueStorage};
    use dojo::world::WorldStorage;

    #[abi(embed_v0)]
    impl PlayerSystemImpl of IPlayerSystem<ContractState> {
        fn initialize(ref self: ContractState) { 
            let caller = get_caller_address();
            let mut world = self.world_default();

            let p: Player = world.read_model(caller);
            p.assert_not_exists();
            let mut player: PlayerData = Default::default();

            player.id = caller;
            player.hp = 100;
            player.max_hp = 100;
            player.mana = 100;
            player.max_mana = 100;
            world.write_model(@player);
        }
        // Combat
        fn take_damage(ref self: ContractState, player_address: ContractAddress, amount: u16) {}
        fn heal(ref self: ContractState, player_address: ContractAddress, amount: u16) {}
        fn is_alive(self: @ContractState, player_address: ContractAddress) -> bool {
            false
        }
        // Currency
        fn add_coins(ref self: ContractState, player_address: ContractAddress, amount: u64) {}
        fn spend_coins(ref self: ContractState, player_address: ContractAddress, amount: u64) {}
        fn add_gems(ref self: ContractState, player_address: ContractAddress, amount: u64) {}
        fn spend_gems(ref self: ContractState, player_address: ContractAddress, amount: u64) {}
        // Equipment
        fn equip_ability(
            ref self: ContractState, player_address: ContractAddress, ability_id: u256,
        ) {}
        fn activate_tower(ref self: ContractState, player_address: ContractAddress) {}
        // Upgrades
        fn upgrade_max_hp(ref self: ContractState, player_address: ContractAddress, value: u16) {}
        // --- Getters ---
        fn get_hp(self: @ContractState, player_address: ContractAddress) -> u16 {
            0
        }
        fn get_max_hp(self: @ContractState, player_address: ContractAddress) -> u16 {
            0
        }
        fn get_coins(self: @ContractState, player_address: ContractAddress) -> u64 {
            0
        }
        fn get_gems(self: @ContractState, player_address: ContractAddress) -> u64 {
            0
        }
        fn get_equipped_ability(self: @ContractState, player_address: ContractAddress) -> u256 {
            0
        }
        fn get_active_towers(self: @ContractState, player_address: ContractAddress) -> u8 {
            0
        }

        fn get_mana(self: @ContractState, player_address: ContractAddress) -> u8 {
            0
        }
        fn get_max_mana(self: @ContractState, player_address: ContractAddress) -> u8 {
            0
        }
        fn spend_mana(ref self: ContractState, player_address: ContractAddress, amount: u8) {}
        fn regenerate_mana(ref self: ContractState, player_address: ContractAddress, amount: u8) {}
        fn get_ability_cooldown(
            self: @ContractState, player_address: ContractAddress, ability_id: u256,
        ) -> u64 {
            0
        }
        fn set_ability_cooldown(
            ref self: ContractState,
            player_address: ContractAddress,
            ability_id: u256,
            cooldown_until: u64,
        ) {}
        fn has_ability_equipped(
            self: @ContractState, player_address: ContractAddress, ability_id: u256,
        ) -> bool {
            false
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn world_default(self: @ContractState) -> WorldStorage {
            self.world(@"stark_brawl")
        }
    }
}
