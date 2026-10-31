# Drawing work on the laptop uses the private automated-drawing-generator, which stays out of Vellum

Zach's private repository `millZach/automated-drawing-generator` already turns project data into loop drawings, IO lists, BOMs and L5X, rewrites loop-sheet DXFs, checks its output by plotting through AutoCAD's own `accoreconsole`, and holds a library of attributed loop-drawing blocks. A "create drawing" or redline job runs on the laptop as a thread that uses that repository and its block library. Vellum's code does not import it, and none of its blocks, client names or project data are copied into Vellum, which is public.

## Consequences

- Create drawing makes P&IDs, loop drawings (through the generator's loop-sheet tools), panel and equipment arrangements, one-lines and wiring diagrams, and plant layout drawings.
- A create-drawing job copies the title block, layers and standards of a template drawing Zach picks on the send screen, found through the drawing index.
- Blocks come first from the drawing being changed, then from the client's library in its Dropbox folder, then from a general ISA symbol set. Linework with no matching block stays as clean lines on its own layer and is listed in the job's results.
