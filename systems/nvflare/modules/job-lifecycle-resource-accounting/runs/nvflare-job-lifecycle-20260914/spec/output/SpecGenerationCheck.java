import tlc2.tool.impl.ModelConfig;
import tlc2.tool.impl.FastTool;
import tlc2.tool.StateVec;
import tlc2.tool.TLCState;
import tlc2.tool.Action;
import util.SimpleFilenameToStream;

// Generation-time expression checks only: no TLC search, simulation, worker,
// fingerprint set, counterexample hunt, or implementation trace replay.
public class SpecGenerationCheck {
  public static void main(String[] args) {
    SimpleFilenameToStream resolver = new SimpleFilenameToStream();
    ModelConfig cfg = new ModelConfig(args[1], resolver);
    cfg.parse();
    System.out.println("CFG_PARSE_OK " + args[1]);
    if (args.length > 2 && args[2].equals("parse-only")) return;
    FastTool tool = new FastTool(args[0], args[1].replaceFirst("\\.cfg$", ""), resolver);
    StateVec initial = tool.getInitStates();
    if (initial.size() != 1) throw new AssertionError("expected one initial state, got " + initial.size());
    TLCState state = initial.elementAt(0);
    if (!tool.isGoodState(state)) throw new AssertionError("unassigned initial variable");
    Action[] invariants = tool.getInvariants();
    for (int i=0; i<invariants.length; i++) {
      if (!tool.isValid(invariants[i], state)) throw new AssertionError("initial invariant false: " + tool.getInvNames()[i]);
    }
    tool.getSymmetryPerms();
    int successors = 0;
    for (Action action : tool.getActions()) {
      StateVec next = tool.getNextStates(action, state);
      for (int i=0; i<next.size(); i++) {
        if (!tool.isGoodState(next.elementAt(i))) throw new AssertionError("unassigned successor variable");
        for (int k=0; k<invariants.length; k++) {
          if (!tool.isValid(invariants[k], next.elementAt(i))) throw new AssertionError("one-step invariant false: " + tool.getInvNames()[k]);
        }
        successors++;
      }
    }
    if (args.length > 2 && args[2].startsWith("expect=")) {
      int expected = Integer.parseInt(args[2].substring(7));
      if (successors != expected) throw new AssertionError("expected successors " + expected + ", got " + successors);
    }
    System.out.println("ONE_STEP_EXPRESSIONS_OK " + args[1] + " successors=" + successors);
    System.out.println("INITIAL_EXPRESSIONS_OK " + args[1] + " invariants=" + invariants.length);
  }
}
