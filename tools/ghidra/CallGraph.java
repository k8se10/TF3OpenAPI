// For each function address given: the functions that call it and the functions it calls.
// Args: addresses..., output file. Lines: "F <entry> <size>", "  caller <entry> <size> at <site>", "  callee <entry> <size>".
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class CallGraph extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        try (PrintWriter out = new PrintWriter(new FileWriter(args[args.length - 1], true))) {
            for (int i = 0; i < args.length - 1; i++) {
                Function f = getFunctionContaining(toAddr(args[i]));
                if (f == null) { out.println("F " + args[i] + " NO FUNCTION"); continue; }
                out.println("F " + f.getEntryPoint() + " " + f.getBody().getNumAddresses());
                Set<String> seen = new LinkedHashSet<>();
                for (Reference r : getReferencesTo(f.getEntryPoint())) {
                    Function c = getFunctionContaining(r.getFromAddress());
                    String kind = r.getReferenceType().isCall() ? "caller" : "ref";
                    if (c == null) seen.add("  " + kind + " - - at " + r.getFromAddress());
                    else seen.add("  " + kind + " " + c.getEntryPoint() + " " + c.getBody().getNumAddresses() + " at " + r.getFromAddress());
                }
                for (String s : seen) out.println(s);
                Set<Address> callees = new TreeSet<>();
                InstructionIterator it = currentProgram.getListing().getInstructions(f.getBody(), true);
                while (it.hasNext()) {
                    Instruction ins = it.next();
                    if (!ins.getFlowType().isCall()) continue;
                    for (Reference r : ins.getReferencesFrom()) {
                        if (r.getReferenceType().isCall()) callees.add(r.getToAddress());
                    }
                }
                for (Address a : callees) {
                    Function c = getFunctionAt(a);
                    out.println("  callee " + a + " " + (c == null ? "-" : String.valueOf(c.getBody().getNumAddresses())));
                }
            }
        }
    }
}
