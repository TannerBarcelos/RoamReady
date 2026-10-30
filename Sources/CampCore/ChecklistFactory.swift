import Foundation

/// Original, conservative prompts informed by Camping World's setup/teardown guide.
/// The rig manufacturer's instructions take priority over this general checklist.
public enum ChecklistFactory {
    public static func template(for rig: some RigDetails) -> ChecklistTemplate {
        var setup: [ChecklistStepDraft] = []
        var teardown: [ChecklistStepDraft] = []
        func arrive(_ title: String, _ detail: String, _ section: String) {
            setup.append(ChecklistStepDraft(title: title, detail: detail, section: section))
        }
        func depart(_ title: String, _ detail: String, _ section: String) {
            teardown.append(ChecklistStepDraft(title: title, detail: detail, section: section))
        }

        arrive("Confirm your site", "Check the site number, boundaries, campground rules, and any local fire or weather notices.", "Arrival")
        arrive("Walk the site before parking", "Look for soft ground, overhead branches, obstructions, and a clear exit. Check where people, pets, and utility connections will be.", "Arrival")

        if rig.type.isRV {
            arrive("Position the rig safely", "Check space for doors, steps, hookups, and any slides. Use a spotter where helpful; stop if you lose sight of them.", "Position & secure")
            arrive("Follow your rig's leveling and securing procedure", "Use your owner's manual for the order of parking, chocking, leveling, and stabilizing. Leveling systems differ; stabilizers are not generally lifting jacks. Keep people clear of moving equipment.", "Position & secure")
            if rig.type.isTowable {
                arrive("Unhitch using your towing instructions", "Confirm the trailer is secured against movement and properly supported before separating the hitch. Follow the hitch and trailer manuals for the exact sequence.", "Position & secure")
            }
            if rig.type == .popUp {
                arrive("Raise and secure the camper", "Follow the manufacturer's instructions for roof supports, beds, and fabric. Check clearances and keep hands away from pinch points.", "Position & secure")
            }
            if rig.equipment.slideOuts {
                arrive("Prepare and extend slides", "Confirm the required rig position, power, and leveling conditions in your manual. Clear the interior and exterior travel paths before operating slides.", "Position & secure")
            }
            if rig.equipment.shorePower {
                arrive("Check and connect shore power", "Use a compatible service and properly rated connection equipment. Follow the pedestal, protection-device, and RV instructions. Stop if equipment is damaged, hot, wet, or reports a fault.", "Connections")
            }
            if rig.equipment.freshWater {
                arrive("Connect or prepare drinking water", "Use a potable-water hose and any pressure regulator or filtration your rig requires. Check connections for leaks and use the correct supply setting.", "Connections")
                arrive("Confirm water-heater readiness", "Before enabling heat, confirm the heater has the required water supply and configuration using its manual. Do not assume the tank is full.", "Connections")
            }
            if rig.equipment.sewer {
                arrive("Prepare the wastewater connection", "Wear gloves, use the designated sewer connection, and secure the hose and fittings. Follow campground rules and your tank-system instructions for valve positions and disposal.", "Connections")
            }
            if rig.equipment.propane {
                arrive("Check propane equipment before use", "Follow the appliance and rig manuals. If you smell gas, avoid ignition sources, move people away, and contact emergency or qualified service assistance from a safe place.", "Safety & comfort")
            }
            arrive("Check alarms and emergency access", "Confirm smoke and carbon-monoxide alarms work, applicable gas detectors are ready, and exits are unobstructed. Keep generators outdoors with exhaust away from occupied spaces.", "Safety & comfort")
        } else {
            arrive("Choose a safe sleeping spot", "Use the designated area. Avoid drainage channels, unstable ground, and damaged overhead branches. Keep vehicles and tents clear of roads and hazards.", "Camp setup")
            if rig.type == .tent {
                arrive("Pitch and secure your tent", "Follow your tent instructions, stake or anchor for the conditions, and keep ventilation openings clear.", "Camp setup")
            } else {
                arrive("Prepare your sleeping space", "Park safely and arrange a clear exit and appropriate ventilation. Never run an engine or fuel-burning device to heat an enclosed sleeping space.", "Camp setup")
            }
            arrive("Set up drinking water and cooking space", "Keep fuel-burning equipment outdoors, away from sleeping spaces and combustible materials. Use safe drinking water and follow local fire restrictions.", "Camp setup")
        }
        arrive("Secure food and outdoor gear", "Follow local wildlife rules for food and scented items. Check wind conditions before setting up an awning or canopy; secure loose gear.", "Settle in")
        arrive("Save your site details", "Record the site number, what you like, and anything to remember. Add a photo for your next visit.", "Settle in")

        depart("Review departure conditions", "Check the route, weather information available to you, campground checkout time, and nearby people or obstacles.", "Pack up")
        depart("Pack loose gear and clean the site", "Stow outdoor items and food securely. Dispose of rubbish properly and fully extinguish any fire according to campground instructions.", "Pack up")
        if rig.type.isRV {
            depart("Secure the interior for travel", "Latch drawers and doors, secure loose items, and configure appliances and vents according to their travel instructions.", "Pack up")
            if rig.equipment.sewer {
                depart("Empty tanks at an approved location", "Follow your system's disposal instructions and local rules. Wear gloves, secure connections, close and cap fittings, and keep wastewater equipment separate from drinking-water supplies.", "Disconnect")
            }
            if rig.equipment.freshWater {
                depart("Disconnect and stow water gear", "Configure pumps and water heating for departure according to your manual. Turn off the supply, release pressure as directed, and stow clean hoses away from wastewater gear.", "Disconnect")
            }
            if rig.equipment.shorePower {
                depart("Disconnect and stow shore power", "Follow your electrical equipment instructions to shut down and disconnect safely. Check that cables and adapters are accounted for.", "Disconnect")
            }
            if rig.equipment.propane {
                depart("Configure propane for travel", "Follow the rig and appliance instructions and route restrictions, including tunnels or ferries. Check that equipment and compartments are secured.", "Travel readiness")
            }
            if rig.equipment.slideOuts {
                depart("Retract and check slides", "Clear slide paths and follow the manual's required leveling and power conditions. Confirm seals and travel locks where fitted.", "Travel readiness")
            }
            if rig.type == .popUp {
                depart("Lower and latch the camper", "Use the manufacturer's folding procedure; protect fabric and confirm all roof and travel latches are secured.", "Travel readiness")
            }
            if rig.type.isTowable {
                depart("Hitch and verify the towing connection", "Follow your hitch and trailer manuals for support and coupling order. Verify the locking mechanism, applicable chains and breakaway cable, electrical connection, brakes, and lights.", "Travel readiness")
            }
            depart("Complete your rig's departure sequence", "Use the manufacturer's order for retracting supports, recovering blocks or chocks, and securing steps and awnings. Do not remove protection against movement before the rig is safely controlled.", "Travel readiness")
            depart("Walk around the entire rig", "Check tires, lights, doors, storage latches, roof equipment, and all connections. Confirm nothing remains attached to the site and the route out is clear.", "Final check")
        } else {
            if rig.type == .tent {
                depart("Pack your tent and sleep kit", "Collect stakes and guylines. If equipment is damp, plan to dry it promptly after the trip.", "Pack up")
            }
            depart("Secure your load", "Stow camping equipment so it cannot shift in transit. Keep the driver's visibility clear and check vehicle lights and tires.", "Final check")
        }
        depart("Leave the site ready for the next camper", "Take a final look for belongings, rubbish, and damage. Save any site notes while the details are fresh.", "Final check")
        return ChecklistTemplate(setup: setup, teardown: teardown)
    }
}
