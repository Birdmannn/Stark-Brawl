use starknet::ContractAddress;

#[starknet::interface]
pub trait IBrawlGame<T> {
    fn join_game(ref self: T);
    fn use_ability(ref self: T, ability_id: u32, target_id: ContractAddress);
    fn take_damage(ref self: T, amount: u32);
    fn attack_enemy(ref self: T, enemy_id: u64, damage: u32);
    fn get_player_status(ref self: T) -> PlayerStatus;
    fn use_item(ref self: T, item_id: u32, inventory_id: u32);
    fn create_ability(
        ref self: T,
        ability_id: u256,
        ability_type: felt252,
        power: u256,
        cooldown: u8,
        mana_cost: u8,
        level_required: u8,
    ) -> u256;
}

#[derive(Copy, Default, Drop, Serde)]
pub enum PlayerStatus {
    Alive,
    Dead,
    InGame,
    #[default]
    Waiting,
}


#[dojo::contract]
pub mod brawl_game {
    use super::{IBrawlGame, PlayerStatus};
    use starknet::storage::{StoragePointerWriteAccess, StoragePointerReadAccess};
    use starknet::{ContractAddress, get_caller_address, get_block_timestamp};

    use dojo::model::{ModelStorage};

    use stark_brawl::models::ability::{
        Ability, AbilityTrait, AbilityUsageContext, AbilityEffectType,
    };
    use stark_brawl::models::player::{Player, PlayerTrait, spawn_player, ZeroablePlayerTrait};

    use stark_brawl::models::item::{Item, ItemType};
    use stark_brawl::models::inventory::{Inventory, InventoryTrait};
    use stark_brawl::models::enemy::{Enemy, EnemySystem};
    use stark_brawl::store::{Store, StoreImpl};
    use stark_brawl::systems::player::{IPlayerSystemDispatcher, IPlayerSystemDispatcherTrait};

    use core::num::traits::Bounded;

    #[storage]
    struct Storage {
        game_counter: u32,
        player_system_contract_address: ContractAddress,
    }

    fn dojo_init(ref self: ContractState, player_system_contract_address: ContractAddress) {
        self.game_counter.write(0);
        self.player_system_contract_address.write(player_system_contract_address);
    }

    #[abi(embed_v0)]
    impl BrawlGameImpl of IBrawlGame<ContractState> {
        fn join_game(ref self: ContractState) {
            let mut world = self.world_default();
            let caller = get_caller_address();
            let existing_player: Player = world.read_model(caller);

            if existing_player.is_zero() {
                let player = spawn_player(caller);
                world.write_model(@player);
            } else {
                assert(!existing_player.in_game, 'Player already in active game');
                let mut player = existing_player;
                player.in_game = true;
                world.write_model(@player);
            }

            let player_system_dispatcher = self.player_system_dispatcher();
            player_system_dispatcher.initialize(caller);
        }

        fn use_ability(ref self: ContractState, ability_id: u32, target_id: ContractAddress) {
            let mut world = self.world_default();
            let caller = get_caller_address();
            let current_timestamp = get_block_timestamp();
            let player_system_dispatcher = self.player_system_dispatcher();

            // Check if the player exists
            let player: Player = world.read_model(caller);
            assert(!player.is_zero(), 'Player does not exist');
            assert(player.in_game, 'Player not in active game');

            // Check if the ability exists
            let ability: Ability = world.read_model(ability_id);
            assert(ability.is_non_zero(), 'Ability not found');

            // Gather validation data
            let player_level = player.level;
            let player_mana = player_system_dispatcher.get_mana(caller);
            let cooldown_until = player_system_dispatcher
                .get_ability_cooldown(caller, ability_id.into());
            let is_player_alive = player_system_dispatcher.is_alive(caller);
            let is_ability_equipped = player_system_dispatcher
                .has_ability_equipped(caller, ability_id.into());
            let is_target_valid = self.validate_target(target_id);

            // Validate ability requirements using AbilityTrait::validate
            ability.validate(player_level, player_mana);

            // Additional validations
            assert(is_player_alive, 'Player not alive');
            assert(is_ability_equipped, 'Ability not equipped');
            assert(current_timestamp >= cooldown_until, 'Ability on cooldown');
            assert(is_target_valid, 'Invalid target');

            // Create usage context
            let context = AbilityUsageContext {
                ability_id: ability_id.into(), caster: caller, target: target_id, current_timestamp,
            };

            // Process ability usage
            let usage_result = ability
                .process_usage(
                    context,
                    player_level,
                    player_mana,
                    cooldown_until,
                    is_player_alive,
                    is_ability_equipped,
                    is_target_valid,
                );

            // Apply costs and effects
            player_system_dispatcher.spend_mana(caller, usage_result.mana_consumed);
            player_system_dispatcher
                .set_ability_cooldown(caller, ability_id.into(), usage_result.cooldown_until);
            self
                .apply_ability_effect(
                    usage_result.effect_type,
                    usage_result.effect_amount,
                    target_id,
                    is_target_valid,
                );
        }

        fn take_damage(ref self: ContractState, amount: u32) {
            let caller = get_caller_address();
            let mut world = self.world_default();
            let player: Player = world.read_model(caller);

            assert(!player.is_zero(), 'Player does not exist');
            assert(player.in_game, 'Player not in active game');

            let player_system_dispatcher = self.player_system_dispatcher();

            assert(amount <= Bounded::MAX, 'Damage too large');

            let damage_amount: u16 = amount.try_into().unwrap();
            player_system_dispatcher.take_damage(caller, damage_amount);

            // Check if died and cleanup game session
            if !player_system_dispatcher.is_alive(caller) {
                let mut dead_player = player;
                dead_player.in_game = false;
                world.write_model(@dead_player);
            }
        }

        fn attack_enemy(ref self: ContractState, enemy_id: u64, damage: u32) {
            let caller = get_caller_address();
            let world = self.world_default();
            let player: Player = world.read_model(caller);
            assert(!player.is_zero(), 'Player does not exist');
            assert(player.in_game, 'Player not in active game');

            let player_system_dispatcher = self.player_system_dispatcher();
            assert(player_system_dispatcher.is_alive(caller), 'Player not alive');

            // Instantiate the Store to interact with models
            let mut store: Store = StoreImpl::new(world);

            // Read the current state of the enemy
            let enemy: Enemy = store.read_enemy(enemy_id);

            // CHECK to ensure we're not attacking a dead enemy
            assert(enemy.is_alive, 'Enemy is already dead');

            // Apply damage to the enemy
            let damaged_enemy = EnemySystem::take_damage(@enemy, damage);

            // Write the enemy's new state back to storage
            store.write_enemy(@damaged_enemy);

            // CHECK if the enemy was defeated in this attack
            if !damaged_enemy.is_alive {
                // 6. If so, call the store to distribute rewards to the attacker
                store
                    .distribute_rewards(
                        self.player_system_contract_address.read(), enemy_id, caller,
                    );
            }
        }

        fn get_player_status(ref self: ContractState) -> PlayerStatus {
            let caller = get_caller_address();
            let world = self.world_default();
            let player: Player = world.read_model(caller);

            if player.is_zero() {
                return PlayerStatus::Waiting;
            }

            let player: Player = world.read_model(caller);
            let player_system_dispatcher = self.player_system_dispatcher();
            let alive = player_system_dispatcher.is_alive(caller);

            if player.in_game {
                PlayerStatus::InGame
            } else if alive {
                PlayerStatus::Alive
            } else {
                PlayerStatus::Dead
            }
        }

        fn use_item(ref self: ContractState, item_id: u32, inventory_id: u32) {
            let mut world = self.world_default();
            let caller = get_caller_address();

            // Validate player exists
            let player: Player = world.read_model(caller);
            assert(!player.is_zero(), 'Player does not exist');
            assert(player.in_game, 'Player not in active game');

            // Validate player is alive
            let player_system_dispatcher = self.player_system_dispatcher();
            let is_player_alive = player_system_dispatcher.is_alive(caller);
            assert(is_player_alive, 'Player not alive');

            // Validate item exists
            let item: Item = world.read_model(item_id);
            assert(item.name.len() != 0, 'Item not found');
            assert(item.usable, 'Item not usable');

            // Validate item is in inventory
            let mut inventory: Inventory = world.read_model(inventory_id);
            assert(inventory.is_non_zero(), 'No inventory for player');
            let has_item = inventory.has_item(item_id);
            assert(has_item, 'Item not in inventory');

            // Remove item from inventory
            let removed = inventory.remove_item(item_id);
            assert(removed, 'Failed to remove item');

            // Apply item effects based on type
            match item.item_type {
                ItemType::Trap => {
                    // Apply trap effect: temporary defense boost
                    // Assuming trap creates a temporary shield effect
                    player_system_dispatcher.upgrade_max_hp(caller, item.value);
                },
                ItemType::Upgrade => {
                    // Apply upgrade effect: permanent max HP increase
                    player_system_dispatcher.upgrade_max_hp(caller, item.value);
                },
                ItemType::Consumable => {
                    // Apply consumable effect: heal player
                    player_system_dispatcher.heal(caller, item.value);
                },
            }

            // Update inventory in storage
            world.write_model(@inventory);
        }

        fn create_ability(
            ref self: ContractState,
            ability_id: u256,
            ability_type: felt252,
            power: u256,
            cooldown: u8,
            mana_cost: u8,
            level_required: u8,
        ) -> u256 {
            let mut world = self.world_default();

            let ability = Ability {
                id: ability_id, name: ability_type, power, cooldown, mana_cost, level_required,
            };

            world.write_model(@ability);

            ability_id
        }
    }

    #[generate_trait]
    pub impl PathSystemImpl of PathSystemTrait {
        /// Returns the (x, y) coordinates for the given path_id and step index
        fn get_path_step(path_id: u64, index: u32) -> (u32, u32) {
            // Predefined paths
            match path_id {
                0 => {
                    // Path 0: Simple straight line from left to right
                    let path_0_steps = array![
                        (0_u32, 5_u32), // Start at (0, 5)
                        (1_u32, 5_u32),
                        (2_u32, 5_u32),
                        (3_u32, 5_u32),
                        (4_u32, 5_u32),
                        (5_u32, 5_u32) // End at (5, 5)
                    ];
                    Self::get_step_from_array(path_0_steps.span(), index)
                },
                1 => {
                    // Path 1: L-shaped path
                    let path_1_steps = array![
                        (0_u32, 0_u32), // Start at (0, 0)
                        (0_u32, 1_u32),
                        (0_u32, 2_u32),
                        (0_u32, 3_u32),
                        (1_u32, 3_u32),
                        (2_u32, 3_u32),
                        (3_u32, 3_u32) // End at (3, 3)
                    ];
                    Self::get_step_from_array(path_1_steps.span(), index)
                },
                2 => {
                    // Path 2: Zigzag pattern
                    let path_2_steps = array![
                        (0_u32, 2_u32), // Start
                        (1_u32, 2_u32),
                        (2_u32, 2_u32),
                        (2_u32, 1_u32),
                        (2_u32, 0_u32),
                        (3_u32, 0_u32),
                        (4_u32, 0_u32),
                        (4_u32, 1_u32),
                        (4_u32, 2_u32) // End
                    ];
                    Self::get_step_from_array(path_2_steps.span(), index)
                },
                _ => panic!("Invalid path_id"),
            }
        }

        /// Moves an enemy to the next valid step in its path
        /// Returns an updated Enemy with new x, y coordinates
        fn advance_enemy_position(ref enemy: Enemy, path_id: u64, current_index: u32) -> Enemy {
            let next_index = current_index + 1;

            // Check if we've reached the end of the path
            if Self::is_path_completed(path_id, next_index) {
                // Enemy has completed the path - return current enemy unchanged
                enemy
            } else {
                // Get the next position
                let (next_x, next_y) = Self::get_path_step(path_id, next_index);

                EnemySystem::move_to(@enemy, next_x, next_y)
            }
        }

        /// Checks whether the enemy has reached the last step of its path
        fn is_path_completed(path_id: u64, index: u32) -> bool {
            // Get the path length for each predefined path
            let path_length = match path_id {
                0 => 6_u32, // Path 0 has 6 steps (indices 0-5)
                1 => 7_u32, // Path 1 has 7 steps (indices 0-6)  
                2 => 9_u32, // Path 2 has 9 steps (indices 0-8)
                _ => panic!("Invalid path_id"),
            };

            index >= path_length
        }

        /// Get a step from a Span of coordinates
        fn get_step_from_array(steps: Span<(u32, u32)>, index: u32) -> (u32, u32) {
            assert(index < steps.len(), 'Index out of bounds');
            *steps.at(index.into())
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn world_default(self: @ContractState) -> dojo::world::WorldStorage {
            self.world(@"stark_brawl")
        }

        fn player_system_dispatcher(self: @ContractState) -> IPlayerSystemDispatcher {
            IPlayerSystemDispatcher { contract_address: self.player_system_contract_address.read() }
        }

        fn validate_target(self: @ContractState, target_id: ContractAddress) -> bool {
            let world = self.world_default();
            let player_system_dispatcher = self.player_system_dispatcher();
            let target_player: Player = world.read_model(target_id);

            if target_player.is_zero() {
                true // TODO: Non-player targets are valid?
            } else {
                player_system_dispatcher.is_alive(target_id)
            }
        }

        fn apply_ability_effect(
            ref self: ContractState,
            effect_type: AbilityEffectType,
            effect_amount: u32,
            target: ContractAddress,
            target_is_valid_player: bool,
        ) {
            if !target_is_valid_player {
                return;
            }

            let player_system_dispatcher = self.player_system_dispatcher();

            match effect_type {
                AbilityEffectType::Damage => {
                    let damage_amount: u16 = effect_amount.try_into().unwrap();
                    player_system_dispatcher.take_damage(target, damage_amount);

                    // Check if died and cleanup game session
                    if !player_system_dispatcher.is_alive(target) {
                        let mut world = self.world_default();
                        let mut target_player: Player = world.read_model(target);
                        target_player.in_game = false;
                        world.write_model(@target_player);
                    }
                },
                AbilityEffectType::Heal => {
                    let heal_amount: u16 = effect_amount.try_into().unwrap();
                    player_system_dispatcher.heal(target, heal_amount);
                },
                AbilityEffectType::Shield => {
                    let boost_amount: u16 = effect_amount.try_into().unwrap();
                    player_system_dispatcher.upgrade_max_hp(target, boost_amount);
                },
                AbilityEffectType::ManaRestore => {
                    let mana_amount: u8 = effect_amount.try_into().unwrap();
                    player_system_dispatcher.regenerate_mana(target, mana_amount);
                },
                AbilityEffectType::DamageOverTime => {
                    let damage_amount: u16 = effect_amount.try_into().unwrap();
                    player_system_dispatcher.take_damage(target, damage_amount);

                    // Check if died and cleanup game session
                    if !player_system_dispatcher.is_alive(target) {
                        let mut world = self.world_default();
                        let mut target_player: Player = world.read_model(target);
                        target_player.in_game = false;
                        world.write_model(@target_player);
                    }
                },
            }
        }
    }
}
