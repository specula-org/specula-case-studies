import tlc2.tool.impl.ModelConfig;
import util.SimpleFilenameToStream;
class ParseConfigs {
    public static void main(String[] args) {
        for (String path : args) {
            ModelConfig config = new ModelConfig(path, new SimpleFilenameToStream());
            config.parse();
            System.out.println("PARSED " + path + " invariants=" + config.getInvariants()
                + " properties=" + config.getProperties());
        }
    }
}
