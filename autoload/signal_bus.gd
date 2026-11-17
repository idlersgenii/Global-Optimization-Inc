extends Node
## Global, autoloaded signal bus for cross-system communication.
##
## Registered in Project Settings > Autoload as `SignalBus`.
## Gameplay systems emit events here; UI, audio, achievements and analytics
## subscribe without holding direct references to each other.
##
## This node must stay stateless: it only routes typed events. Game state
## belongs to the systems that own it.

# --- Enums -----------------------------------------------------------------

enum GameScale {
	CAFE = 0,
	CORPORATION = 1,
	SPACE_AUDIT = 2,
	SINGULARITY = 3,
}

enum HRSeverity {
	INFO = 0,
	WARNING = 1,
	CRITICAL = 2,
}

# --- Currency and economy --------------------------------------------------

signal coffee_changed(new_amount: float)
signal coffee_earned(amount: float)
signal coffee_spent(amount: float)
signal coffee_cups_changed(new_count: int)
signal pure_logic_changed(new_amount: float)
signal metaverse_shares_changed(new_amount: float)
signal currency_changed(currency_id: StringName, new_amount: float)

# --- Production and employees ----------------------------------------------

signal grind_boost_requested(amount: float)
signal coffee_brewed(amount: float)
signal production_rate_changed(cups_per_second: float)
signal click_power_changed(new_power: float)
signal production_multiplier_changed(new_multiplier: float)
signal click_multiplier_changed(new_multiplier: float)
signal fatigue_changed(new_value: float)
signal intern_efficiency_changed(new_efficiency: float)
signal intern_exhausted()
signal intern_cheered(recovery: float)
signal employee_hired(employee_id: StringName)
signal employee_fired(employee_id: StringName)
signal employee_state_changed(employee_id: StringName, state: StringName)

# --- Upgrades --------------------------------------------------------------

signal upgrade_availability_changed(upgrade_id: StringName, is_available: bool)
signal upgrade_purchase_requested(upgrade_id: StringName)
signal upgrade_purchased(upgrade_id: StringName, cost: float)
signal upgrade_effect_triggered(upgrade_id: StringName, payload: Dictionary[StringName, Variant])
signal upgrade_tree_changed()

# --- HR events and notifications -------------------------------------------

signal hr_event_triggered(event_id: StringName, payload: Dictionary[StringName, Variant])
signal hr_choice_made(event_id: StringName, choice_id: StringName)
signal hr_notification_received(title: String, message: String, severity: HRSeverity)
signal morale_changed(new_value: float)
signal oxygen_level_changed(new_level: float)

# --- Scale and progression -------------------------------------------------

signal scale_changed(new_scale: GameScale)
signal scope_creep_triggered(new_scale: GameScale)
signal zoom_out_requested(target_scale: GameScale)
signal optimization_progress_changed(progress_percent: float)
signal universe_optimized()
signal prestige_triggered(metaverse_shares_earned: float)

# --- Game flow -------------------------------------------------------------

signal game_started()
signal game_paused(is_paused: bool)
signal game_reset()
signal game_saved(save_slot: StringName)
signal game_loaded(save_slot: StringName)

# --- UI and feedback -------------------------------------------------------

signal notification_requested(title: String, message: String, severity: HRSeverity)
signal ticker_message_added(message: String)
signal achievement_unlocked(achievement_id: StringName)

# --- Audio -----------------------------------------------------------------

signal audio_phase_changed(phase: GameScale)
