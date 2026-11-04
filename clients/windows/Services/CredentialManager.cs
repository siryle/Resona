using System.Runtime.InteropServices;
using System.Text;

namespace Resona.Windows.Services;

public static class CredentialManager
{
    private const int CredTypeGeneric = 1;
    private const int CredPersistLocalMachine = 2;
    private const string SessionTarget = "ResonaSession";

    public static void SaveToken(string token)
    {
        ArgumentNullException.ThrowIfNull(token);
        Write(SessionTarget, token);
    }

    public static string? ReadToken() => Read(SessionTarget);

    public static void DeleteToken() => Delete(SessionTarget);

    public static void Write(string target, string secret)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(secret);
        var password = Encoding.Unicode.GetBytes(secret);
        var blob = Marshal.AllocHGlobal(password.Length);
        Marshal.Copy(password, 0, blob, password.Length);
        var credential = new Credential
        {
            Type = CredTypeGeneric,
            TargetName = target,
            CredentialBlobSize = (uint)password.Length,
            CredentialBlob = blob,
            Persist = CredPersistLocalMachine,
            UserName = "resona",
        };
        try
        {
            if (!CredWrite(ref credential, 0))
            {
                throw new InvalidOperationException($"CredWrite failed with error {Marshal.GetLastWin32Error()}.");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public static string? Read(string target)
    {
        if (!CredRead(target, CredTypeGeneric, 0, out var credential))
        {
            return null;
        }

        try
        {
            if (credential.CredentialBlobSize == 0 || credential.CredentialBlob == IntPtr.Zero)
            {
                return null;
            }

            var bytes = new byte[credential.CredentialBlobSize];
            Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
            return Encoding.Unicode.GetString(bytes);
        }
        finally
        {
            CredFree(credential.CredentialBlob);
        }
    }

    public static void Delete(string target) => CredDelete(target, CredTypeGeneric, 0);

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(string target, int type, uint flags, out Credential credential);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(string target, int type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
}
