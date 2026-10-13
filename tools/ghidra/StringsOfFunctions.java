// For each function start listed in a file (one hex address a line; anything after the first blank is kept
// as a label), writes every text the function refers to, in the order of the references.
// Args: list file, output file. Output: "F <address> <label>" then one "\t<text>" a line.
// Used to read out which keys a file-format reader of the game asks for.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class StringsOfFunctions extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        Listing listing = currentProgram.getListing();
        try (BufferedReader in = new BufferedReader(new FileReader(args[0]));
             PrintWriter out = new PrintWriter(new FileWriter(args[1]))) {
            String line;
            Set<Address> done = new HashSet<>();
            while ((line = in.readLine()) != null && !monitor.isCancelled()) {
                line = line.trim();
                if (line.isEmpty()) continue;
                int cut = line.indexOf(' ');
                String addressText = cut < 0 ? line : line.substring(0, cut);
                String label = cut < 0 ? "" : line.substring(cut + 1);
                Function f = getFunctionContaining(toAddr(addressText));
                if (f == null || !done.add(f.getEntryPoint())) continue;
                out.println("F " + f.getEntryPoint() + " " + label);
                LinkedHashSet<String> texts = new LinkedHashSet<>();
                InstructionIterator it = listing.getInstructions(f.getBody(), true);
                while (it.hasNext()) {
                    Instruction ins = it.next();
                    for (Reference r : ins.getReferencesFrom()) {
                        Data d = getDataAt(r.getToAddress());
                        if (d == null) d = getDataContaining(r.getToAddress());
                        if (d != null && d.hasStringValue() && d.getValue() instanceof String) {
                            String s = (String) d.getValue();
                            if (s.length() >= 2 && s.length() <= 80 && !s.contains("\\") && !s.contains("\n")) texts.add(s);
                        }
                    }
                }
                for (String s : texts) out.println("\t" + s);
            }
        }
    }
}
