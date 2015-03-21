#include <QStringList>
#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include "finder-sync/finder-sync.h"
#include "utils/utils-mac.h"

namespace {
const char* kApplePluginkitBinary = "/usr/bin/pluginkit";
const char* kFinderSyncBundleIdentifier =
    "com.seafile.seafile-client.findersync";

// run command and arugments,
// and return the termination status
// if we have non-null output, we will write stdout (not stderr) output to it
int runAsCommand(const QString &binary, const QStringList &arguments, QString
                 *output = nullptr) {
    QProcess process;
    process.start(binary, arguments);
    if (!process.waitForFinished(500))
        return false;
    if (output)
        *output = process.readAllStandardOutput().trimmed();
    return process.exitCode();
}

#ifdef XCODE_APP
inline QString pluginPath() {
    return QDir(utils::mac::mainBundlePath()).filePath("Contents/PlugIns/Seafile FinderSync.appex");
}
#endif
} // anonymous namespace

bool FinderSyncExtensionHelper::isInstalled() {
    QString output;
    QStringList arguments {"-m", "-i", kFinderSyncBundleIdentifier};
    int status = runAsCommand(kApplePluginkitBinary, arguments, &output);
    if (status != 0 || output.isEmpty())
        return false;

    return true;
}

bool FinderSyncExtensionHelper::isEnabled() {
    QString output;
    QStringList arguments {"-m", "-i", kFinderSyncBundleIdentifier};
    int status = runAsCommand(kApplePluginkitBinary, arguments, &output);
    if (status != 0 || output.isEmpty())
        return false;
    if (output[0] != '+' && output[0] != '?')
        return false;

    return true;
}

bool FinderSyncExtensionHelper::isBundled() {
#ifdef XCODE_APP
    QString plugin_path = pluginPath();
    if (!QFileInfo(plugin_path).isDir())
        return false;

    return true;
#else
    return false;
#endif
}

bool FinderSyncExtensionHelper::reinstall() {
#ifdef XCODE_APP
    QString plugin_path = pluginPath();
    if (!QFileInfo(plugin_path).isDir())
        return false;

    QStringList remove_arguments {"-r", plugin_path};
    QStringList arguments {"-a", plugin_path};
    runAsCommand(kApplePluginkitBinary, remove_arguments);
    int status = runAsCommand(kApplePluginkitBinary, arguments);
    if (status != 0)
        return false;

    qWarning("FinderSync reinstalled");
    return true;
#else
    return false;
#endif
}

bool FinderSyncExtensionHelper::setEnable(bool enable) {
    const char *election = enable ? "use" : "ignore";
    QStringList arguments {"-e", election, "-i", kFinderSyncBundleIdentifier};
    int status = runAsCommand(kApplePluginkitBinary, arguments);
    if (status != 0)
        return false;

    return true;
}
