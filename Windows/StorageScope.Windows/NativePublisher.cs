using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

namespace StorageScope.Windows;

// Windows system files may be catalogue-signed rather than carrying an embedded certificate.
// Verify the member hash and obtain the publisher from the verified WinTrust signer chain.
internal static class NativePublisher
{
    internal static bool Verify(string path, string organization)
    {
        var file = new TrustFile { Size = (uint)Marshal.SizeOf<TrustFile>(), Path = path };
        if (Trust(file, 1, organization)) return true;
        if (!CryptCATAdminAcquireContext2(out var admin, IntPtr.Zero, "SHA256", IntPtr.Zero, 0)) return false;
        try {
            using var input = File.OpenRead(path); var handle = input.SafeFileHandle.DangerousGetHandle(); uint length = 0;
            if (!CryptCATAdminCalcHashFromFileHandle2(admin, handle, ref length, null, 0) || length is 0 or > 128) return false;
            var hash = new byte[length]; if (!CryptCATAdminCalcHashFromFileHandle2(admin, handle, ref length, hash, 0)) return false;
            var previous = IntPtr.Zero;
            var catalog = CryptCATAdminEnumCatalogFromHash(admin, hash, length, 0, ref previous);
            if (catalog == IntPtr.Zero) return false;
            try {
                    var info = new CatalogInfo { Size = (uint)Marshal.SizeOf<CatalogInfo>(), Path = "" };
                    if (CryptCATCatalogInfoFromContext(catalog, ref info, 0)) {
                        var data = new TrustCatalog { Size = (uint)Marshal.SizeOf<TrustCatalog>(), CatalogPath = info.Path, MemberTag = Convert.ToHexString(hash), MemberPath = path, MemberHandle = handle, Admin = admin };
                        return Trust(data, 2, organization);
                    }
                    return false;
            }
            finally { CryptCATAdminReleaseCatalogContext(admin, catalog, 0); }
        }
        finally { CryptCATAdminReleaseContext(admin, 0); }
    }
    private static bool Trust<T>(T subject, uint choice, string organization) where T : struct
    {
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
        var data = new TrustData { Size = (uint)Marshal.SizeOf<TrustData>(), UI = 2, Revocation = 1, Choice = choice, Subject = pointer, StateAction = 1, Flags = 0x0080 };
        var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
        try {
            Marshal.StructureToPtr(subject, pointer, false);
            if (WinVerifyTrust(IntPtr.Zero, ref action, ref data) != 0 || data.State == IntPtr.Zero) return false;
            var provider = WTHelperProvDataFromStateData(data.State);
            if (provider == IntPtr.Zero) return false;
            var signerPointer = WTHelperGetProvSignerFromChain(provider, 0, false, 0);
            if (signerPointer == IntPtr.Zero) return false;
            var signer = Marshal.PtrToStructure<SignerPrefix>(signerPointer);
            if (signer.Certificates == 0 || signer.Chain == IntPtr.Zero) return false;
            var cert = Marshal.PtrToStructure<CertPrefix>(signer.Chain);
#pragma warning disable SYSLIB0057
            using var certificate = new X509Certificate2(cert.Context);
#pragma warning restore SYSLIB0057
            return certificate.SubjectName.Decode(X500DistinguishedNameFlags.UseNewLines).Split('\n').Any(line => line.Trim() == "O=" + organization);
        }
        finally { data.StateAction = 2; WinVerifyTrust(IntPtr.Zero, ref action, ref data); Marshal.DestroyStructure<T>(pointer); Marshal.FreeHGlobal(pointer); }
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct TrustFile { public uint Size; [MarshalAs(UnmanagedType.LPWStr)] public string Path; public IntPtr Handle, Subject; }
    [StructLayout(LayoutKind.Sequential)] private struct TrustData { public uint Size; public IntPtr Callback, Client; public uint UI, Revocation, Choice; public IntPtr Subject; public uint StateAction; public IntPtr State, URL; public uint Flags, UIContext; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct TrustCatalog { public uint Size, Version; [MarshalAs(UnmanagedType.LPWStr)] public string CatalogPath; [MarshalAs(UnmanagedType.LPWStr)] public string MemberTag; [MarshalAs(UnmanagedType.LPWStr)] public string MemberPath; public IntPtr MemberHandle, Hash; public uint HashLength; public IntPtr Context, Admin; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct CatalogInfo { public uint Size; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string Path; }
    [StructLayout(LayoutKind.Sequential)] private struct SignerPrefix { public uint Size, TimeLow, TimeHigh, Certificates; public IntPtr Chain; }
    [StructLayout(LayoutKind.Sequential)] private struct CertPrefix { public uint Size; public IntPtr Context; }
    [DllImport("wintrust.dll", ExactSpelling=true)] private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
    [DllImport("wintrust.dll", ExactSpelling=true)] private static extern IntPtr WTHelperProvDataFromStateData(IntPtr state);
    [DllImport("wintrust.dll", ExactSpelling=true)] private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint index, [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterIndex);
    [DllImport("wintrust.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CryptCATAdminAcquireContext2(out IntPtr context, IntPtr subsystem, string algorithm, IntPtr policy, uint flags);
    [DllImport("wintrust.dll", ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CryptCATAdminCalcHashFromFileHandle2(IntPtr context, IntPtr file, ref uint length, [Out] byte[]? hash, uint flags);
    [DllImport("wintrust.dll", ExactSpelling=true)] private static extern IntPtr CryptCATAdminEnumCatalogFromHash(IntPtr context, byte[] hash, uint length, uint flags, ref IntPtr previous);
    [DllImport("wintrust.dll", CharSet=CharSet.Unicode, ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CryptCATCatalogInfoFromContext(IntPtr context, ref CatalogInfo info, uint flags);
    [DllImport("wintrust.dll", ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CryptCATAdminReleaseCatalogContext(IntPtr context, IntPtr catalog, uint flags);
    [DllImport("wintrust.dll", ExactSpelling=true)] [return:MarshalAs(UnmanagedType.Bool)] private static extern bool CryptCATAdminReleaseContext(IntPtr context, uint flags);
}
