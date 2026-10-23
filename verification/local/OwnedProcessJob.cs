using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Nbiot.Runtime {
    // A private Windows job owns the process from BEFORE its first instruction.
    // Children stay in the job even if parents exit; closing it kills only this job.
    public sealed class OwnedProcessJob : IDisposable {
        private IntPtr job = IntPtr.Zero, process = IntPtr.Zero;
        public uint RootProcessId { get; private set; }
        public OwnedProcessJob(string executable, string arguments, string directory, string stdout, string stderr)
            : this(executable, arguments, directory, stdout, stderr, true) { }
        public OwnedProcessJob(string executable, string arguments, string directory, string stdout, string stderr, bool killOnClose) {
            IntPtr output = IntPtr.Zero, error = IntPtr.Zero, input = IntPtr.Zero, thread = IntPtr.Zero;
            try {
                job = CreateJobObject(IntPtr.Zero, null); Check(job != IntPtr.Zero);
                ExtendedLimits limits = new ExtendedLimits();
                limits.BasicLimitInformation.LimitFlags = killOnClose ? 0x2000u : 0u;
                Check(SetJobLimits(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(ExtendedLimits))));
                SecurityAttributes security = new SecurityAttributes();
                security.Length = Marshal.SizeOf(typeof(SecurityAttributes)); security.InheritHandle = true;
                output = CreateFile(stdout, 0x40000000, 3, ref security, 2, 0x80, IntPtr.Zero); Check(output != new IntPtr(-1));
                error = CreateFile(stderr, 0x40000000, 3, ref security, 2, 0x80, IntPtr.Zero); Check(error != new IntPtr(-1));
                input = CreateFile("NUL", 0x80000000, 3, ref security, 3, 0x80, IntPtr.Zero); Check(input != new IntPtr(-1));
                StartupInfo startup = new StartupInfo(); startup.Size = Marshal.SizeOf(typeof(StartupInfo));
                startup.Flags = 0x100; startup.Input = input; startup.Output = output; startup.Error = error;
                ProcessInformation created;
                StringBuilder command = new StringBuilder("\"" + executable + "\" " + arguments);
                Check(CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, true, 0x08000004,
                    IntPtr.Zero, directory, ref startup, out created));
                process = created.Process; thread = created.Thread; RootProcessId = created.ProcessId;
                Check(AssignProcessToJobObject(job, process));
                Check(ResumeThread(thread) != UInt32.MaxValue);
            } catch {
                if (process != IntPtr.Zero) TerminateProcess(process, 125);
                Dispose(); throw;
            } finally {
                CloseValid(thread); CloseValid(output); CloseValid(error); CloseValid(input);
            }
        }
        public bool RootExited { get { return WaitForSingleObject(process, 0) == 0; } }
        public int ExitCode { get { uint code; Check(GetExitCodeProcess(process, out code)); return unchecked((int)code); } }
        public uint[] ProcessIds() {
            int bytes = 256;
            while (true) {
                IntPtr buffer = Marshal.AllocHGlobal(bytes);
                try {
                    uint used;
                    if (QueryInformationJobObject(job, 3, buffer, (uint)bytes, out used)) {
                        int count = Marshal.ReadInt32(buffer, 4); List<uint> ids = new List<uint>();
                        for (int i = 0; i < count; i++) ids.Add(unchecked((uint)Marshal.ReadIntPtr(buffer, 8 + i * IntPtr.Size).ToInt64()));
                        return ids.ToArray();
                    }
                    int code = Marshal.GetLastWin32Error();
                    if (code != 234 || bytes >= 1024 * 1024) throw new Win32Exception(code);
                } finally { Marshal.FreeHGlobal(buffer); }
                bytes *= 2;
            }
        }
        public void Stop() {
            Check(TerminateJobObject(job, 124));
            DateTime deadline = DateTime.UtcNow.AddSeconds(5);
            while (ProcessIds().Length != 0) {
                if (DateTime.UtcNow >= deadline) throw new TimeoutException("Owned job did not terminate within cleanup budget.");
                System.Threading.Thread.Sleep(10);
            }
        }
        public void Dispose() {
            CloseValid(job); job = IntPtr.Zero; CloseValid(process); process = IntPtr.Zero;
        }
        private static void Check(bool success) { if (!success) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        private static void CloseValid(IntPtr handle) { if (handle != IntPtr.Zero && handle != new IntPtr(-1)) CloseHandle(handle); }
        [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes {
            public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }
        [StructLayout(LayoutKind.Sequential)] private struct StartupInfo {
            public int Size; public IntPtr Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XCount, YCount, Fill, Flags;
            public ushort ShowWindow, ReservedBytes; public IntPtr ReservedData, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInformation {
            public IntPtr Process, Thread; public uint ProcessId, ThreadId;
        }
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimits {
            public long ProcessTime, JobTime; public uint LimitFlags;
            public UIntPtr MinimumWorkingSet, MaximumWorkingSet; public uint ActiveProcesses;
            public UIntPtr Affinity; public uint Priority, SchedulingClass;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IoCounters {
            public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits {
            public BasicLimits BasicLimitInformation; public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", EntryPoint="SetInformationJobObject", SetLastError=true)] private static extern bool SetJobLimits(IntPtr job, int kind, ref ExtendedLimits limits, uint bytes);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool QueryInformationJobObject(IntPtr job, int kind, IntPtr value, uint bytes, out uint used);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateFile(string name, uint access, uint sharing, ref SecurityAttributes security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool CreateProcess(string application, StringBuilder command, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInformation info);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateProcess(IntPtr process, uint code);
        [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetExitCodeProcess(IntPtr process, out uint code);
        [DllImport("kernel32.dll")] private static extern uint WaitForSingleObject(IntPtr process, uint milliseconds);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    }
}
