// Lists strings matching a regular expression and the functions that refer to each.
// Args: regex, output file. Output: string address, text, then one line per referring function (entry, size).
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;
import java.util.regex.*;

public class StrXrefs extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        // names joined by "+" (the batch launcher mangles regex characters); exact matches
        Pattern p = Pattern.compile("^(" + args[0].replace("+", "|") + ")$");
        ReferenceManager refs = currentProgram.getReferenceManager();
        try (PrintWriter out = new PrintWriter(new FileWriter(args[1], true))) {
            DataIterator it = currentProgram.getListing().getDefinedData(true);
            while (it.hasNext() && !monitor.isCancelled()) {
                Data d = it.next();
                if (!d.hasStringValue()) continue;
                Object v = d.getValue();
                if (!(v instanceof String) || !p.matcher((String) v).find()) continue;
                out.println(d.getAddress() + "\t" + ((String) v).replace("\n", "\\n"));
                Set<Address> seen = new TreeSet<>();
                ReferenceIterator ri = refs.getReferencesTo(d.getAddress());
                while (ri.hasNext()) {
                    Reference r = ri.next();
                    Function f = getFunctionContaining(r.getFromAddress());
                    if (f == null) { out.println("\tref from " + r.getFromAddress() + " (no function)"); continue; }
                    if (seen.add(f.getEntryPoint())) out.println("\t" + f.getEntryPoint() + "\t" + f.getBody().getNumAddresses() + "\tat " + r.getFromAddress());
                }
            }
        }
    }
}
