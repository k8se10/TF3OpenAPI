// Recovers function names from assertion call sites: a call whose RDX is a source-file path and whose R9
// is a text is taken as assert(expr, file, line, function). For each such site:
//   containing function entry \t function size \t name (R9) \t file \t line (R8D) \t expression (RCX) \t site
// Args: output file.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.scalar.Scalar;
import java.io.*;
import java.util.*;

public class AssertNames extends GhidraScript {
    private String str(Address a) {
        if (a == null) return null;
        Data d = getDataAt(a);
        if (d != null && d.hasStringValue() && d.getValue() instanceof String) return (String) d.getValue();
        return null;
    }

    @Override
    public void run() throws Exception {
        String outPath = getScriptArgs()[0];
        Listing listing = currentProgram.getListing();
        ReferenceManager refs = currentProgram.getReferenceManager();
        // every instruction that loads a source path into RDX
        Set<Address> sites = new TreeSet<>();
        DataIterator it = listing.getDefinedData(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Data d = it.next();
            if (!d.hasStringValue()) continue;
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String s = (String) v;
            if (!s.contains("urban_games") || !(s.endsWith(".cpp") || s.endsWith(".h") || s.endsWith(".hpp") || s.endsWith(".inl"))) continue;
            ReferenceIterator ri = refs.getReferencesTo(d.getAddress());
            while (ri.hasNext()) sites.add(ri.next().getFromAddress());
        }
        int written = 0;
        try (PrintWriter out = new PrintWriter(new FileWriter(outPath))) {
            for (Address site : sites) {
                Instruction lea = listing.getInstructionAt(site);
                if (lea == null) continue;
                Function f = getFunctionContaining(site);
                if (f == null) continue;
                String file = null, name = null, expr = null; long line = -1;
                // look a few instructions either side of the path load, up to the call
                Instruction start = lea;
                for (int i = 0; i < 8 && start.getPrevious() != null; i++) start = start.getPrevious();
                Instruction ins = start;
                for (int i = 0; i < 20 && ins != null; i++, ins = ins.getNext()) {
                    String m = ins.getMnemonicString();
                    if (ins.getAddress().compareTo(site) > 0 && m.equals("CALL")) break;
                    Object[] dst = ins.getOpObjects(0);
                    if (dst.length != 1 || !(dst[0] instanceof Register)) continue;
                    String reg = ((Register) dst[0]).getName();
                    if (m.equals("LEA")) {
                        String s = null;
                        for (Reference r : ins.getReferencesFrom()) { s = str(r.getToAddress()); if (s != null) break; }
                        if (s == null) continue;
                        if (reg.equals("RDX")) file = s;
                        else if (reg.equals("R9")) name = s;
                        else if (reg.equals("RCX")) expr = s;
                    } else if (m.equals("MOV") && (reg.equals("R8D") || reg.equals("R8"))) {
                        Object[] src = ins.getOpObjects(1);
                        if (src.length == 1 && src[0] instanceof Scalar) line = ((Scalar) src[0]).getUnsignedValue();
                    }
                }
                if (file == null || name == null) continue;
                int cut = file.replace('\\', '/').indexOf("urban_games/");
                String shortFile = cut < 0 ? file : file.replace('\\', '/').substring(cut + 12);
                out.println(f.getEntryPoint() + "\t" + f.getBody().getNumAddresses() + "\t" + name + "\t" + shortFile + "\t" + line + "\t"
                    + (expr == null ? "" : expr.replace("\t", " ").replace("\n", " ")) + "\t" + site);
                written++;
            }
        }
        println("assert sites: " + sites.size() + ", with a name: " + written);
    }
}
