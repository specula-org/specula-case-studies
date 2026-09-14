import tlc2.tool.impl.FastTool;
import tlc2.tool.impl.ModelConfig;
import tlc2.tool.StateVec;
import tlc2.tool.Action;
import util.SimpleFilenameToStream;

// Artifact check only: parse/configure, evaluate Init and its immediate successors. No search loop.
class ConfigInitCheck {
  public static void main(String[] args) {
    String module = args[0];
    String cfg = args[1];
    var resolver = new SimpleFilenameToStream();
    if (module.equals("Trace")) {
      var config = new ModelConfig(cfg, resolver);
      config.parse();
      System.out.println("CONFIG_ONLY_OK " + cfg + " properties=" + config.getProperties());
      return;
    }
    var tool = new FastTool(module, cfg.replaceFirst("\\.cfg$", ""), resolver);
    if (tool.checkAssumptions() != 0) throw new AssertionError("constant assumptions failed");
    StateVec initial = tool.getInitStates();
    if (initial.size() != 1) throw new AssertionError("expected one initial state, got " + initial.size());
    var state = initial.elementAt(0);
    if (!tool.isGoodState(state)) throw new AssertionError("unassigned initial variable");
    Action[] inv = tool.getInvariants();
    for (int i=0; i<inv.length; i++) {
      if (!tool.isValid(inv[i], state)) throw new AssertionError(tool.getInvNames()[i]);
    }
    var next = tool.getNextStates(tool.getNextStateSpec(), state);
    for (int j=0;j<next.size();j++) {
      if (!tool.isGoodState(next.elementAt(j))) throw new AssertionError("unassigned first successor variable");
      for (int i=0;i<inv.length;i++) if (!tool.isValid(inv[i], next.elementAt(j))) throw new AssertionError(tool.getInvNames()[i]);
    }
    System.out.println("CONFIG_INIT_OK " + cfg + " invariants=" + inv.length + " initial_states=1 first_successors="+next.size()+" max_depth=1");
  }
}
