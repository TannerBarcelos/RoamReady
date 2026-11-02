# Ingredient amounts are structured, and `quantity` stays as a retired field

Free-text amounts couldn't be added up on the Grocery list, so an Ingredient's amount is now a number and a unit chosen from lists, stored in new optional attributes. `DishItem.quantity` was already in the Production CloudKit schema, where a field can't be removed or change type, so it stays on the model unread and unwritten, and its name can't be reused for the number.

Old menu data was deleted rather than converted, because the only affected data belonged to one tester. New meals carry a marker attribute and the delete targets meals without it. A per-device "run once" flag or a date cutoff could let a second device delete a menu already rebuilt on the first.
