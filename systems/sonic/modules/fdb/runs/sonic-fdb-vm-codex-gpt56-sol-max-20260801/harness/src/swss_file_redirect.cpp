// Test-environment shim for swsscommon's compile-time /usr/share/swss path.
// SONiC packages place the Lua scripts there; the harness extracts packages
// without root and points this function at the equivalent local directory.

#include <cstdlib>
#include <fstream>
#include <iterator>
#include <stdexcept>
#include <string>

namespace swss
{

std::string readTextFile(const std::string &requested)
{
    std::string path = requested;
    const std::string packagedPrefix = "/usr/share/swss/";
    const char *localShare = std::getenv("FDB_SWSS_SHARE_DIR");
    if (localShare != nullptr && requested.compare(0, packagedPrefix.size(), packagedPrefix) == 0)
    {
        path = std::string(localShare) + "/" + requested.substr(packagedPrefix.size());
    }

    std::ifstream input(path);
    if (!input)
    {
        throw std::runtime_error(":- readTextFile: failed to read file: '" + path + "'");
    }
    return std::string(std::istreambuf_iterator<char>(input),
                       std::istreambuf_iterator<char>());
}

} // namespace swss
