// For each data address given: the functions that refer to it (entry, size, site).
// Args: addresses..., output file.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class DataXrefs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        try (PrintWriter out = new PrintWriter(new FileWriter(args[args.length - 1], true))) {
            for (int i = 0; i < args.length - 1; i++) {
                Address a = toAddr(args[i]);
                out.println("F " + a + " (data)");
                Set<String> seen = new LinkedHashSet<>();
                for (Reference r : getReferencesTo(a)) {
                    Function f = getFunctionContaining(r.getFromAddress());
                    seen.add(f == null ? "  ref - - at " + r.getFromAddress()
                                       : "  ref " + f.getEntryPoint() + " " + f.getBody().getNumAddresses() + " at " + r.getFromAddress());
                }
                for (String s : seen) out.println(s);
            }
        }
    }
}
