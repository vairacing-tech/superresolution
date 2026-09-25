"""Run the actual Java factor writer in isolation; no Android/device access."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'common/src/main/java/io/homo/superresolution/common/config/SuperResolutionConfig.java').read_text(encoding='utf-8')
start = source.index('    public static void writeEarlyFactorConfig(')
end = source.index('    public static synchronized void applyFrameGenerationToNative()', start)
writer = source[start:end]
with tempfile.TemporaryDirectory(prefix='lsfg-factor-') as directory:
    root = Path(directory)
    harness = root / 'FactorContract.java'
    harness.write_text('public class FactorContract {\n' + writer + r'''
    public static void main(String[] args) throws Exception {
        final String sandbox = new java.io.File(args[0]).getCanonicalPath();
        System.setSecurityManager(new SecurityManager() {
            public void checkPermission(java.security.Permission permission) {}
            public void checkWrite(String file) {
                try {
                    String target = new java.io.File(file).getCanonicalPath();
                    if (!target.startsWith(sandbox + java.io.File.separator))
                        throw new SecurityException("Outside isolated test directory");
                } catch (java.io.IOException e) { throw new SecurityException(e); }
            }
        });
        for (String variant : new String[]{"release files", "debug files"}) {
            java.nio.file.Path target = java.nio.file.Path.of(sandbox, variant, "lsfg_factor.cfg");
            System.setProperty("amethyst.lsfg.factorConfig", target.toString());
            writeEarlyFactorConfig(3);
            if (!java.nio.file.Files.exists(target))
                throw new AssertionError("Factor writer ignored launcher path: " + variant);
            if (!java.nio.file.Files.readString(target).equals("factor=3\n")) throw new AssertionError();
            writeEarlyFactorConfig(2);
            if (!java.nio.file.Files.readString(target).equals("factor=2\n")) throw new AssertionError();
        }
        System.out.println("PASS: release/debug factor persistence at launcher-supplied path");
    }
}
''', encoding='utf-8')
    # JDK 17 supports the sandbox used to prevent the old writer touching its absolute debug path.
    jdk = Path('C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot/bin')
    subprocess.run([str(jdk / 'javac.exe'), str(harness)], check=True)
    subprocess.run([str(jdk / 'java.exe'), '-cp', str(root), 'FactorContract', str(root)], check=True)
