// Finds functions that store a float at given displacements from a register and step a pointer by a given
// element size: the shape of a loop that updates one field in every element of an array of structures.
// Args: displacements joined by + (hex, e.g. 3c+38), element size (hex), output file.
// Lines: "<function entry> <size> stores@<disp>=<count> ... steps=<count> first=<address>".
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.scalar.Scalar;
import java.io.*;
import java.util.*;

public class FloatStores extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        List<Long> disps = new ArrayList<>();
        for (String s : args[0].split("\\+")) disps.add(Long.parseLong(s, 16));
        long step = Long.parseLong(args[1], 16);
        Map<Address, long[]> hits = new LinkedHashMap<>();   // per function: counts per displacement, then steps
        Map<Address, Address> first = new HashMap<>();
        Listing listing = currentProgram.getListing();
        InstructionIterator it = listing.getInstructions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Instruction in = it.next();
            String m = in.getMnemonicString();
            boolean store = m.equals("MOVSS") || m.equals("VMOVSS");
            boolean add = m.equals("ADD") || m.equals("LEA");
            if (!store && !add) continue;
            if (store) {
                // destination is operand 0; a store has a memory operand there
                Object[] objs = in.getOpObjects(0);
                boolean hasReg = false; Long disp = null;
                for (Object o : objs) {
                    if (o instanceof ghidra.program.model.lang.Register) hasReg = true;
                    if (o instanceof Scalar) disp = ((Scalar) o).getUnsignedValue();
                }
                if (!hasReg || disp == null || in.getOperandRefType(0) == null || !in.getOperandRefType(0).isWrite()) continue;
                int k = disps.indexOf(disp);
                if (k < 0) continue;
                Function f = getFunctionContaining(in.getAddress());
                if (f == null) continue;
                long[] c = hits.computeIfAbsent(f.getEntryPoint(), a -> new long[disps.size() + 1]);
                c[k]++;
                first.putIfAbsent(f.getEntryPoint(), in.getAddress());
            } else {
                boolean found = false;
                for (int op = 1; op < in.getNumOperands() && !found; op++)
                    for (Object o : in.getOpObjects(op))
                        if (o instanceof Scalar && ((Scalar) o).getUnsignedValue() == step) found = true;
                if (!found) continue;
                Function f = getFunctionContaining(in.getAddress());
                if (f == null) continue;
                long[] c = hits.get(f.getEntryPoint());
                if (c != null) c[disps.size()]++;
                else { c = new long[disps.size() + 1]; c[disps.size()] = 1; hits.put(f.getEntryPoint(), c); }
            }
        }
        try (PrintWriter out = new PrintWriter(new FileWriter(args[2]))) {
            for (Map.Entry<Address, long[]> e : hits.entrySet()) {
                long[] c = e.getValue();
                long stores = 0;
                for (int k = 0; k < disps.size(); k++) stores += c[k];
                if (stores == 0 || c[disps.size()] == 0) continue;
                Function f = getFunctionAt(e.getKey());
                StringBuilder sb = new StringBuilder(e.getKey() + " " + f.getBody().getNumAddresses());
                for (int k = 0; k < disps.size(); k++) sb.append(" stores@" + Long.toHexString(disps.get(k)) + "=" + c[k]);
                sb.append(" steps=" + c[disps.size()] + " first=" + first.get(e.getKey()));
                out.println(sb);
            }
        }
    }
}
