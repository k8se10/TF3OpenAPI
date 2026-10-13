// For every string in the program that names a source file (.cpp/.h), list the functions that refer to it.
// Output (tab separated): source file, function entry, function size in bytes, number of references.
// Args: output file.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.data.*;
import java.io.*;
import java.util.*;

public class FuncsBySource extends GhidraScript {
    @Override
    public void run() throws Exception {
        String outPath = getScriptArgs()[0];
        Listing listing = currentProgram.getListing();
        ReferenceManager refs = currentProgram.getReferenceManager();
        Map<String, Map<Address, Integer>> byFile = new TreeMap<>();
        DataIterator it = listing.getDefinedData(true);
        int strings = 0;
        while (it.hasNext() && !monitor.isCancelled()) {
            Data d = it.next();
            if (!(d.getDataType() instanceof StringDataType) && !d.hasStringValue()) continue;
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String s = ((String) v).replace('\\', '/');
            int cut = s.indexOf("urban_games/");
            if (cut < 0) continue;
            if (!(s.endsWith(".cpp") || s.endsWith(".h") || s.endsWith(".hpp") || s.endsWith(".inl"))) continue;
            String file = s.substring(cut + "urban_games/".length());
            strings++;
            ReferenceIterator ri = refs.getReferencesTo(d.getAddress());
            while (ri.hasNext()) {
                Reference r = ri.next();
                Function f = getFunctionContaining(r.getFromAddress());
                if (f == null) continue;
                byFile.computeIfAbsent(file, k -> new TreeMap<>()).merge(f.getEntryPoint(), 1, Integer::sum);
            }
        }
        try (PrintWriter out = new PrintWriter(new FileWriter(outPath))) {
            for (Map.Entry<String, Map<Address, Integer>> e : byFile.entrySet()) {
                for (Map.Entry<Address, Integer> fe : e.getValue().entrySet()) {
                    Function f = getFunctionAt(fe.getKey());
                    out.println(e.getKey() + "\t" + fe.getKey() + "\t" + f.getBody().getNumAddresses() + "\t" + fe.getValue());
                }
            }
        }
        println("source strings: " + strings + ", files with functions: " + byFile.size());
    }
}
