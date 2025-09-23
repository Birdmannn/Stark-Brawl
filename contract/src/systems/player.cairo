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
    id: ContractAddress,
    hp: u16,
    max_hp: u16,
    coins: u64,
    gems: u64,
    equipped_ability: u256,
    active_towers: u8,
    mana: u8,
    max_mana: u8,
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
    use crate::models::player::{Player, AssertTrait};
    use super::{PlayerData, AC};
    use dojo::model::{Model, ModelStorage, ModelValueStorage};
    use dojo::world::WorldStorage;
    use core::num::traits::SaturatingSub;


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
        fn take_damage(ref self: ContractState, player_address: ContractAddress, amount: u16) {
            self.player_exists(player_address);
            let mut world = self.world_default();
            let target = selector!("hp");
            let current_hp: u16 = world
                .read_member(Model::<PlayerData>::ptr_from_keys(player_address), target);

            let new_hp = current_hp.saturating_sub(amount);
            world.write_member(Model::<PlayerData>::ptr_from_keys(player_address), target, new_hp);
        }

        fn heal(ref self: ContractState, player_address: ContractAddress, amount: u16) {
            // let current_hp = self.hp.entry(player_address).read();
            // let max_hp = self.max_hp.entry(player_address).read();
            // let new_hp = core::cmp::min(current_hp + amount, max_hp);
            // self.hp.entry(player_address).write(new_hp);
            let mut world = self.world_default();
            self.player_exists(player_address);
            let m = selector!("max_hp");
            let h = selector!("hp");
            let max_hp = world.read_member(Model::<PlayerData>::ptr_from_keys(player_address), m);
            let current_hp = world
                .read_member(Model::<PlayerData>::ptr_from_keys(player_address), h);
            let new_hp = core::cmp::min(current_hp + amount, max_hp);
            world.write_member(Model::<PlayerData>::ptr_from_keys(player_address), h, new_hp);
        }

        fn is_alive(self: @ContractState, player_address: ContractAddress) -> bool {
            let mut world = self.world_default();
            let h = selector!("hp");
            let hp = world.read_member(Model::<PlayerData>::ptr_from_keys(player_address), h);
            hp > 0
        }

        // Currency
        fn add_coins(ref self: ContractState, player_address: ContractAddress, amount: u64) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let c = selector!("coins");
            let coins = world.read_member(Model::<PlayerData>::ptr_from_keys(player_address), c);
            world
                .write_member(
                    Model::<PlayerData>::ptr_from_keys(player_address), c, coins + amount,
                );
        }

        fn spend_coins(ref self: ContractState, player_address: ContractAddress, amount: u64) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let c = selector!("coins");
            let coins = world.read_member(Model::<PlayerData>::ptr_from_keys(player_address), c);
            assert!(amount <= coins, "amount {} greater than balance {}", amount, coins);
            world
                .write_member(
                    Model::<PlayerData>::ptr_from_keys(player_address), c, coins - amount,
                );
        }

        // // Equipment
        // fn equip_ability(
        //     ref self: ContractState, player_address: ContractAddress, ability_id: u256,
        // ) {
        //     self.equipped_ability.entry(player_address).write(ability_id);
        // }

        fn add_gems(ref self: ContractState, player_address: ContractAddress, amount: u64) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let g = selector!("gems");
            let gems = world.read_member(Model::<PlayerData>::ptr_from_keys(player_address), g);
            world
                .write_member(Model::<PlayerData>::ptr_from_keys(player_address), g, gems + amount);
        }

        fn spend_gems(ref self: ContractState, player_address: ContractAddress, amount: u64) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let g = selector!("gems");
            let gems = world.read_member(Model::<PlayerData>::ptr_from_keys(player_address), g);
            assert!(amount <= gems, "amount {} greater than gems {}", amount, gems);
            world
                .write_member(Model::<PlayerData>::ptr_from_keys(player_address), g, gems - amount);
        }

        fn equip_ability(
            ref self: ContractState, player_address: ContractAddress, ability_id: u256,
        ) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let eq = selector!("equipped_ability");
            world.write_member(Model::<PlayerData>::ptr_from_keys(player_address), eq, ability_id);
        }

        fn activate_tower(ref self: ContractState, player_address: ContractAddress) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let k = Model::<PlayerData>::ptr_from_keys(player_address);
            let t = selector!("active_towers");
            let towers = world.read_member(k, t);
            world.write_member(k, t, towers + 1);
        }

        fn upgrade_max_hp(ref self: ContractState, player_address: ContractAddress, value: u16) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let k = Model::<PlayerData>::ptr_from_keys(player_address);
            let m = selector!("max_hp");
            let max_hp = world.read_member(k, m);
            world.write_member(k, m, max_hp + value);
        }

        // --- Getters ---
        fn get_hp(self: @ContractState, player_address: ContractAddress) -> u16 {
            let h = selector!("hp");
            self.get_data(h, player_address).try_into().unwrap()
        }

        fn get_max_hp(self: @ContractState, player_address: ContractAddress) -> u16 {
            let m = selector!("max_hp");
            self.get_data(m, player_address).try_into().unwrap()
        }

        fn get_coins(self: @ContractState, player_address: ContractAddress) -> u64 {
            let c = selector!("coins");
            self.get_data(c, player_address).try_into().unwrap()
        }

        fn get_gems(self: @ContractState, player_address: ContractAddress) -> u64 {
            let g = selector!("gems");
            self.get_data(g, player_address).try_into().unwrap()
        }

        fn get_equipped_ability(self: @ContractState, player_address: ContractAddress) -> u256 {
            let eq = selector!("equipped_ability");
            self.get_data(eq, player_address)
        }

        fn get_active_towers(self: @ContractState, player_address: ContractAddress) -> u8 {
            self.get_data(selector!("active_towers"), player_address).try_into().unwrap()
        }

        fn get_mana(self: @ContractState, player_address: ContractAddress) -> u8 {
            self.get_data(selector!("mana"), player_address).try_into().unwrap()
        }

        fn get_max_mana(self: @ContractState, player_address: ContractAddress) -> u8 {
            self.get_data(selector!("max_mana"), player_address).try_into().unwrap()
        }

        fn spend_mana(ref self: ContractState, player_address: ContractAddress, amount: u8) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let m = selector!("mana");
            let k = Model::<PlayerData>::ptr_from_keys(player_address);
            let mana = world.read_member(k, m);
            assert!(amount <= mana, "amount {} greater than mana {}", amount, mana);
            world.write_member(k, m, mana - amount);
        }

        fn regenerate_mana(ref self: ContractState, player_address: ContractAddress, amount: u8) {
            let mut world = self.world_default();
            self.player_exists(player_address);
            let m = selector!("mana");
            let mm = selector!("max_mana");
            let k = Model::<PlayerData>::ptr_from_keys(player_address);
            let mana = world.read_member(k, m);
            let max_mana = world.read_member(k, mm);
            let new_mana = core::cmp::min(mana + amount, max_mana);
            world.write_member(k, m, new_mana);
        }

        fn get_ability_cooldown(
            self: @ContractState, player_address: ContractAddress, ability_id: u256,
        ) -> u64 {
            let mut world = self.world_default();
            let k = Model::<AC>::ptr_from_keys((player_address, ability_id));
            let ac = selector!("ability_cooldown");
            world.read_member(k, ac)
        }

        fn set_ability_cooldown(
            ref self: ContractState,
            player_address: ContractAddress,
            ability_id: u256,
            cooldown_until: u64,
        ) {
            let mut world = self.world_default();
            let k = Model::<AC>::ptr_from_keys((player_address, ability_id));
            let ac = selector!("ability_cooldown");
            world.write_member(k, ac, cooldown_until);
        }

        fn has_ability_equipped(
            self: @ContractState, player_address: ContractAddress, ability_id: u256,
        ) -> bool {
            let k = selector!("equipped_ability");
            let equipped_ability = self.get_data(k, player_address);
            equipped_ability == ability_id && ability_id != 0
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn world_default(self: @ContractState) -> WorldStorage {
            self.world(@"stark_brawl")
        }

        fn player_exists(self: @ContractState, player_address: ContractAddress) {
            let mut world = self.world_default();
            let player: Player = world.read_model(player_address);
            player.assert_exists();
            let m = selector!("max_hp");
            let k = Model::<PlayerData>::ptr_from_keys(player_address);
            let max_hp = world.read_member(k, m);
            assert(max_hp > 0, 'Player does not exist.');
        }

        fn get_data(
            self: @ContractState, selector: felt252, player_address: ContractAddress,
        ) -> u256 {
            let mut world = self.world_default();
            world.read_member(Model::<PlayerData>::ptr_from_keys(player_address), selector).into()
        }
    }
}
