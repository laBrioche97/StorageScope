using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using StorageScope.Windows;

internal static class CudaTests
{
    private const string Id = "{B2FE1952-0186-46C3-BAEC-A80AA35AC5B8}_CUDADevelopment_12.1";
    internal static void Run(string root, Action<string, Action> test)
    {
        var windows = Path.Combine(root, "cuda", "Windows"); var programs = Path.Combine(root, "cuda", "Program Files");
        var runner = Path.Combine(windows, "SysWOW64", "rundll32.exe");
        var dll = Path.Combine(programs, "NVIDIA Corporation", "Installer2", "InstallerCore", "NVI2.DLL");
        void Pe(string path, ushort machine = 0x14c) { Directory.CreateDirectory(Path.GetDirectoryName(path)!); using var file = File.Create(path); using var writer = new BinaryWriter(file); writer.Write((ushort)0x5a4d); file.Position = 60; writer.Write(64); writer.Write(0x4550); writer.Write(machine); file.SetLength(128); }
        Pe(runner); Pe(dll);
        var command = $"\"{runner}\" \"{dll}\",UninstallPackage CUDADevelopment_12.1";
        var product = new InstalledApplication("NVIDIA CUDA Development 12.1", "NVIDIA Corporation", "12.1", programs, command, "Application", Id, "LocalMachine|Registry64|" + Id);
        var launched = 0; var absent = false; var signature = true; var registration = true; var refused = false; CancellationTokenSource? cancel = null;
        var provider = new NvidiaCudaProvider { WindowsRoot = windows, ProgramFilesRoot = programs, Checks = 2,
            CheckRegistration = _ => { if (!registration) throw new IOException("changed registration"); },
            VerifyPublisher = (_, _) => signature, TestAbsent = (_, _) => Task.FromResult(absent), Wait = _ => Task.CompletedTask,
            Start = info => { Require(info.FileName == runner && info.Arguments == $"\"{dll}\",UninstallPackage CUDADevelopment_12.1" && info.Verb == "runas"); if (refused) throw new Win32Exception(1223); launched++; cancel?.Cancel(); return null; } };
        test("CUDA parser restricts runner DLL entry point component and every argument", () => {
            NvidiaCudaProvider.Parse(command, Id, windows, programs);
            foreach (var bad in new[] { command + " -silent", command + " & calc.exe", command.Replace("UninstallPackage", "OtherEntry"), command.Replace("CUDADevelopment_12.1", "Display.Driver"), command.Replace(runner, Path.Combine(root, "rundll32.exe")), command.Replace(dll, Path.Combine(root, "NVI2.DLL")) }) Reject(() => NvidiaCudaProvider.Parse(bad, Id, windows, programs));
            Reject(() => NvidiaCudaProvider.Parse(command, Id.Replace("Development", "Document"), windows, programs));
            Reject(() => RegisteredProductProvider.ParseCommand(command));
        });
        test("native publisher verification supports system catalogues and rejects foreign or unsigned files", () => {
            var system = Path.Combine(Environment.SystemDirectory, "rundll32.exe");
            Require(NativePublisher.Verify(system, "Microsoft Corporation"));
            Require(!NativePublisher.Verify(system, "NVIDIA Corporation") && !NativePublisher.Verify(dll, "NVIDIA Corporation"));
        });
        test("CUDA preparation requires signatures matching architectures and exact registered name", () => {
            Require(provider.Prepare(product).NvidiaTarget is not null);
            signature = false; Require(!provider.Prepare(product).CanProceed); signature = true;
            Pe(dll, 0x8664); Require(!provider.Prepare(product).CanProceed); Pe(dll);
            Require(!provider.Prepare(product with { Name = "NVIDIA Graphics Driver" }).CanProceed);
            registration = false; Require(!provider.Prepare(product).CanProceed); registration = true;
        });
        test("CUDA revalidates both identities and registration immediately before launch", () => {
            var plan = provider.Prepare(product); File.SetLastWriteTimeUtc(dll, DateTime.UtcNow.AddMinutes(-5));
            Reject(() => provider.ExecuteAsync(plan, default).GetAwaiter().GetResult()); Require(launched == 0);
            plan = provider.Prepare(product); registration = false;
            Reject(() => provider.ExecuteAsync(plan, default).GetAwaiter().GetResult()); registration = true; Require(launched == 0);
        });
        test("CUDA UAC refusal cancellation and unconfirmed removal never report success", () => {
            var plan = provider.Prepare(product); refused = true; Require(!provider.ExecuteAsync(plan, default).GetAwaiter().GetResult().Verified && launched == 0); refused = false;
            Require(!provider.ExecuteAsync(plan, default).GetAwaiter().GetResult().Verified);
            cancel = new(); Require(!provider.ExecuteAsync(plan, cancel.Token).GetAwaiter().GetResult().Verified); cancel.Dispose(); cancel = null;
            absent = true; Require(provider.ExecuteAsync(plan, default).GetAwaiter().GetResult().Verified);
            Require(File.Exists(dll) && File.Exists(runner));
        });
        test("CUDA shared installation size is labelled and never counted as guaranteed recovery", () => {
            var merged = InstalledProductCatalog.Merge([product, product with { Name = "NVIDIA CUDA Documentation 12.1", ProductId = Id.Replace("Development", "Document"), RegistrationPath = "doc" }]);
            Require(merged.Count == 2 && merged.All(item => item.SharedInstallLocation && item.DisplaySize.Contains("partagé")));
        });
    }
    internal static int ReadOnly()
    {
        var provider = new NvidiaCudaProvider(); var products = provider.DetectAsync(default).GetAwaiter().GetResult();
        foreach (var product in products) { var plan = provider.Prepare(product); Console.WriteLine($"CUDA readonly: {product.Name}; verified={plan.CanProceed}; reason={plan.BlockReason}"); if (!plan.CanProceed) return 1; }
        return products.Count > 0 ? 0 : 2;
    }
    internal static int RunIsolated()
    {
        if (Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true" || Environment.GetEnvironmentVariable("RUNNER_ENVIRONMENT") != "github-hosted" || Environment.GetEnvironmentVariable("STORAGESCOPE_CUDA_DISPOSABLE") != "12.1") throw new InvalidOperationException("Real CUDA uninstall is restricted to a disposable hosted runner.");
        var diagnostics = Path.Combine(Environment.GetEnvironmentVariable("RUNNER_TEMP")!, "cuda-validation");
        Diagnostics.TestDirectory = diagnostics; OperationHistory.TestDirectory = diagnostics;
        var provider = new NvidiaCudaProvider { Checks = 300 };
        var before = provider.DetectAsync(default).GetAwaiter().GetResult();
        var product = before.Single(item => item.Name == "NVIDIA CUDA Development 12.1");
        var docs = before.Single(item => item.Name == "NVIDIA CUDA Documentation 12.1");
        var plan = provider.Prepare(product); Require(plan.CanProceed); Console.WriteLine("CUDA official plan verified: " + plan.NvidiaTarget!.PackageId);
        var result = provider.ExecuteAsync(plan, default).GetAwaiter().GetResult(); Console.WriteLine(result.Message); Require(result.Verified);
        Require(!provider.VerifyAsync(docs, default).GetAwaiter().GetResult());
        Require(before.Where(item => item.ProductId != product.ProductId).All(item => !provider.VerifyAsync(item, default).GetAwaiter().GetResult()));
        Console.WriteLine("PASS real CUDA Development removal; documentation and other CUDA components preserved."); return 0;
    }
    private static void Require(bool value) { if (!value) throw new InvalidOperationException("CUDA validation failed"); }
    private static void Reject(Action action) { try { action(); } catch (IOException) { return; } throw new InvalidOperationException("Unsafe CUDA command accepted"); }
}
