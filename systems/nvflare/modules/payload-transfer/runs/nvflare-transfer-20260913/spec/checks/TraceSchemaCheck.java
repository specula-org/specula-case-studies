import java.nio.file.*;
import java.util.*;
import tlc2.tool.impl.FastTool;
import tlc2.tool.StateVec;
import tlc2.value.impl.*;
import util.SimpleFilenameToStream;

// Synthetic artifact tests only. No implementation trace or state-space search.
class TraceSchemaCheck {
  static String quote(String s) {
    return "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n") + "\"";
  }
  static String encode(Value v) {
    if (v instanceof BoolValue) return v.toString().toLowerCase();
    if (v instanceof IntValue) return v.toString();
    if (v instanceof StringValue) return quote(v.toUnquotedString());
    if (v instanceof ModelValue) return quote(v.toString());
    if (v instanceof RecordValue r) {
      List<String> fields = new ArrayList<>();
      for (int i=0;i<r.names.length;i++) fields.add(quote(r.names[i].toString())+":"+encode(r.values[i]));
      return "{"+String.join(",",fields)+"}";
    }
    if (v instanceof TupleValue t) {
      List<String> elems = new ArrayList<>();
      for (Value x : t.elems) elems.add(encode(x));
      return "["+String.join(",",elems)+"]";
    }
    if (v instanceof SetEnumValue s) {
      List<String> elems = new ArrayList<>();
      for (int i=0;i<s.elems.size();i++) elems.add(encode(s.elems.elementAt(i)));
      return "{\"__tla\":\"set\",\"items\":["+String.join(",",elems)+"]}";
    }
    if (v instanceof FcnRcdValue || v instanceof FcnLambdaValue) {
      FcnRcdValue f = (FcnRcdValue)v.toFcnRcd();
      Value[] domain = f.getDomainAsValues();
      List<String> entries = new ArrayList<>();
      for (int i=0;i<domain.length;i++) entries.add("{\"key\":"+encode(domain[i])+",\"value\":"+encode(f.values[i])+"}");
      return "{\"__tla\":\"function\",\"entries\":["+String.join(",",entries)+"]}";
    }
    throw new AssertionError("unsupported synthetic value: " + v.getClass());
  }
  public static void main(String[] args) throws Exception {
    var resolver = new SimpleFilenameToStream();
    if (args[0].equals("encode-init")) {
      var tool = new FastTool("base", "base", resolver);
      var initial = tool.getInitStates();
      Files.writeString(Path.of("checks/initial-state.json"), encode((Value)initial.elementAt(0).lookup("st"))+"\n");
      System.out.println("SYNTHETIC_INIT_ENCODED");
      return;
    }
    var tool = new FastTool("Trace", "Trace", resolver);
    var initial = tool.getInitStates();
    if (initial.size()!=1) throw new AssertionError("trace bootstrap rejected");
    StateVec next = tool.getNextStates(tool.getNextStateSpec(), initial.elementAt(0));
    int expected = Integer.parseInt(args[0]);
    if (next.size()!=expected) throw new AssertionError("expected "+expected+" synthetic successor(s), got "+next.size());
    if (expected==1) {
      if (!tool.isGoodState(next.first())) throw new AssertionError("unassigned trace next variable");
      for (var invariant : tool.getInvariants()) if (!tool.isValid(invariant,next.first())) throw new AssertionError("synthetic successor invariant");
    }
    System.out.println("SCHEMA_CHECK_OK expected_successors="+expected+" source=synthetic next_steps=1");
  }
}
