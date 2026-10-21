# CC Craft Dispatch

Crafty turtles keep your Create Factory Controller gauges stocked. One **Dispatcher** computer reads the gauges, and for every item that is short and has a learned recipe it orders the ingredients for up to 64 crafts through the **Stock Ticker**, straight to a free turtle's own address. The turtle crafts and sends the result to storage.

No Custom Arrangement, no recipe on the packages, no shared address: each turtle has its own, and the Dispatcher decides who crafts what. Orders are plain Stock Ticker orders, so a Repackager hub just merges the pieces from different vaults.

## Dispatcher (one computer)

**Already running the [Factory Monitor](https://github.com/levisnakes/cc-factory-monitor)?** It has the Dispatcher built in: just put a Stock Ticker on its network. Otherwise use `dispatcher.lua`:

On the same modem network as a **Stock Ticker** (reads stock), a **Redstone Requester** (sends the orders; the Stock Ticker's own ordering crashes on dedicated servers), the **Factory Controller** and the crafters. Link the Redstone Requester to your storage network like the Stock Ticker:

```
wget https://raw.githubusercontent.com/levisnakes/cc-craft-dispatch/main/dispatcher.lua startup.lua
```

Set the crafting gauges to **Passive** (the Dispatcher does the ordering; the gauge target is how many you want in storage). Tabs: Items (stock/target, what's happening), Crafters, Recipes (Forget a recipe), Log. Pause stops new orders.

## Crafter (each turtle)

Crafty Turtle, input Frogport on its front standing on the input Packager (attached to the Barrel under the turtle), output Packager on its back with its own Frogport (unused address), wired modem to the Dispatcher's network.

```
wget https://raw.githubusercontent.com/levisnakes/cc-craft-dispatch/main/crafter.lua startup.lua
```

The turtle sets its input Frogport to its own address, `MB-Crafter-<id>`. Results go to `OUT_ADDRESS` (default `MB-Storage-In`).

**Teach a recipe:** put it in the turtle's 3x3 grid (slots 1-3, 5-7, 9-11, one item per slot is enough) and press **L**. It test-crafts once, tells the Dispatcher, and sends the result home. Every crafter can then make it.

Keys: L learn, S send everything back, P pause, U upload the log to Pastebin.
