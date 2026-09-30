# Ricompila SteamImporter.exe incorporando SteamImporter.ps1 e app.ico dentro l'exe.
# L'exe risultante e' autonomo: se accanto a se' trova SteamImporter.ps1 usa quello
# (comodo per lo sviluppo), altrimenti estrae la copia incorporata in %TEMP% e usa quella.
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$out = Join-Path $dir 'SteamImporter.exe'
$ico = Join-Path $dir 'app.ico'

$ps1B64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dir 'SteamImporter.ps1')))
$icoB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ico))

function To-Chunks([string]$B64) {
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $B64.Length; $i += 400) {
        $len = [Math]::Min(400, $B64.Length - $i)
        [void]$sb.AppendLine('"' + $B64.Substring($i, $len) + '",')
    }
    return $sb.ToString()
}

$code = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

static class Program
{
    static readonly string[] ScriptB64 = {
$(To-Chunks $ps1B64)
    };
    static readonly string[] IconB64 = {
$(To-Chunks $icoB64)
    };

    [STAThread]
    static void Main()
    {
        try
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            string devScript = Path.Combine(exeDir, "SteamImporter.ps1");
            string script, workDir;
            if (File.Exists(devScript))
            {
                // modalita' sviluppo: usa lo script accanto all'exe
                script = devScript;
                workDir = exeDir;
            }
            else
            {
                // modalita' autonoma: estrae la copia incorporata
                workDir = Path.Combine(Path.GetTempPath(), "SteamImporterApp");
                Directory.CreateDirectory(workDir);
                script = Path.Combine(workDir, "SteamImporter.ps1");
                File.WriteAllBytes(script, Convert.FromBase64String(string.Concat(ScriptB64)));
                File.WriteAllBytes(Path.Combine(workDir, "app.ico"), Convert.FromBase64String(string.Concat(IconB64)));
            }
            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"";
            psi.WorkingDirectory = workDir;
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Errore avvio: " + ex.Message, "SteamImporter",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
"@

if (Test-Path $out) { Remove-Item $out -Force }
$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.GenerateExecutable = $true
$cp.OutputAssembly = $out
$cp.GenerateInMemory = $false
$cp.CompilerOptions = "/target:winexe /win32icon:`"$ico`""
[void]$cp.ReferencedAssemblies.Add('System.dll')
[void]$cp.ReferencedAssemblies.Add('System.Windows.Forms.dll')

$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$res = $provider.CompileAssemblyFromSource($cp, $code)
if ($res.Errors.HasErrors) {
    $res.Errors | ForEach-Object { Write-Host "ERR: $_" }
    exit 1
}
Write-Host "SteamImporter.exe ricompilato: $((Get-Item $out).Length) byte (script e icona incorporati)"
