// Decompiles the functions containing each address given as script args; writes to the output file (last arg).
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.app.cmd.function.CreateFunctionCmd;
import java.io.*;

public class DecompileAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outPath = args[args.length - 1];
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        try (PrintWriter out = new PrintWriter(new FileWriter(outPath, true))) {
            for (int i = 0; i < args.length - 1; i++) {
                Address a = toAddr(args[i]);
                Function f = getFunctionContaining(a);
                if (f == null) {
                    disassemble(a);
                    new CreateFunctionCmd(a).applyTo(currentProgram);
                    f = getFunctionAt(a);
                }
                out.println("//////// " + args[i] + " -> " + (f == null ? "NO FUNCTION" : f.getName() + " @ " + f.getEntryPoint()));
                if (f == null) continue;
                DecompileResults r = di.decompileFunction(f, 120, monitor);
                out.println(r.decompileCompleted() ? r.getDecompiledFunction().getC() : ("FAILED: " + r.getErrorMessage()));
            }
        }
    }
}
