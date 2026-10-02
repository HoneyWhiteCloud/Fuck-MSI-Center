# Read-only NVIDIA driver P0 clock-delta range probe.
# Based on NVIDIA's public NV_GPU_PERF_PSTATES20_INFO_V1 layout.

Set-StrictMode -Version Latest

function Initialize-MsiNvapiLimitInterop {
    if (([System.Management.Automation.PSTypeName]'MsiNvapiLimitInteropV1.Reader').Type) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace MsiNvapiLimitInteropV1
{
    public sealed class ClockLimitResult
    {
        public string GpuName;
        public bool InfoEditable;
        public bool CoreEditable;
        public bool MemoryEditable;
        public int CoreValueKHz;
        public int CoreMinimumKHz;
        public int CoreMaximumKHz;
        public int MemoryValueKHz;
        public int MemoryMinimumKHz;
        public int MemoryMaximumKHz;
    }

    public static class Reader
    {
        private const int NvApiOk = 0;
        private const int MaxPhysicalGpus = 64;
        private const int InfoSize = 0x1C94;
        private const int InfoVersion = 0x00011C94;
        private const int HeaderSize = 20;
        private const int PstateSize = 456;
        private const int ClockArrayOffset = 8;
        private const int ClockEntrySize = 44;

        [DllImport("nvapi64.dll", CallingConvention = CallingConvention.Cdecl)]
        private static extern IntPtr nvapi_QueryInterface(uint interfaceId);

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int InitializeDelegate();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int UnloadDelegate();
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int EnumPhysicalGpusDelegate(
            [Out, MarshalAs(UnmanagedType.LPArray, SizeConst = MaxPhysicalGpus)] IntPtr[] handles,
            out uint count);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl, CharSet = CharSet.Ansi)]
        private delegate int GetFullNameDelegate(IntPtr handle, StringBuilder name);
        [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
        private delegate int GetPstates20Delegate(IntPtr handle, IntPtr info);

        private static Delegate Resolve(uint id, Type type)
        {
            IntPtr address = nvapi_QueryInterface(id);
            if (address == IntPtr.Zero)
                throw new InvalidOperationException("nvapi_QueryInterface returned null for 0x" + id.ToString("X8") + ".");
            return Marshal.GetDelegateForFunctionPointer(address, type);
        }

        private static void Check(string operation, int status)
        {
            if (status != NvApiOk)
                throw new InvalidOperationException(operation + " returned NVAPI status " + status + ".");
        }

        public static ClockLimitResult ReadFirstGpuP0Limits()
        {
            InitializeDelegate initialize = (InitializeDelegate)Resolve(0x0150E828, typeof(InitializeDelegate));
            UnloadDelegate unload = (UnloadDelegate)Resolve(0xD22BDD7E, typeof(UnloadDelegate));
            EnumPhysicalGpusDelegate enumerate = (EnumPhysicalGpusDelegate)Resolve(0xE5AC921F, typeof(EnumPhysicalGpusDelegate));
            GetFullNameDelegate getName = (GetFullNameDelegate)Resolve(0xCEEE8E9F, typeof(GetFullNameDelegate));
            GetPstates20Delegate getPstates = (GetPstates20Delegate)Resolve(0x6FF81213, typeof(GetPstates20Delegate));

            Check("NvAPI_Initialize", initialize());
            try
            {
                IntPtr[] handles = new IntPtr[MaxPhysicalGpus];
                uint count;
                Check("NvAPI_EnumPhysicalGPUs", enumerate(handles, out count));
                if (count < 1)
                    throw new InvalidOperationException("NvAPI did not enumerate a physical GPU.");

                StringBuilder name = new StringBuilder(64);
                Check("NvAPI_GPU_GetFullName", getName(handles[0], name));
                IntPtr buffer = Marshal.AllocHGlobal(InfoSize);
                try
                {
                    byte[] zero = new byte[InfoSize];
                    Marshal.Copy(zero, 0, buffer, zero.Length);
                    Marshal.WriteInt32(buffer, InfoVersion);
                    Check("NvAPI_GPU_GetPstates20", getPstates(handles[0], buffer));

                    int numPstates = Marshal.ReadInt32(buffer, 8);
                    int numClocks = Marshal.ReadInt32(buffer, 12);
                    ClockLimitResult result = new ClockLimitResult();
                    result.GpuName = name.ToString();
                    result.InfoEditable = (Marshal.ReadInt32(buffer, 4) & 1) != 0;
                    bool coreFound = false;
                    bool memoryFound = false;

                    for (int pstateIndex = 0; pstateIndex < Math.Min(numPstates, 16); pstateIndex++)
                    {
                        int pstateOffset = HeaderSize + pstateIndex * PstateSize;
                        int pstateId = Marshal.ReadInt32(buffer, pstateOffset);
                        if (pstateId != 0)
                            continue;
                        for (int clockIndex = 0; clockIndex < Math.Min(numClocks, 8); clockIndex++)
                        {
                            int clockOffset = pstateOffset + ClockArrayOffset + clockIndex * ClockEntrySize;
                            int domainId = Marshal.ReadInt32(buffer, clockOffset);
                            bool editable = (Marshal.ReadInt32(buffer, clockOffset + 8) & 1) != 0;
                            int value = Marshal.ReadInt32(buffer, clockOffset + 12);
                            int minimum = Marshal.ReadInt32(buffer, clockOffset + 16);
                            int maximum = Marshal.ReadInt32(buffer, clockOffset + 20);
                            if (domainId == 0)
                            {
                                result.CoreEditable = editable;
                                result.CoreValueKHz = value;
                                result.CoreMinimumKHz = minimum;
                                result.CoreMaximumKHz = maximum;
                                coreFound = true;
                            }
                            else if (domainId == 4)
                            {
                                result.MemoryEditable = editable;
                                result.MemoryValueKHz = value;
                                result.MemoryMinimumKHz = minimum;
                                result.MemoryMaximumKHz = maximum;
                                memoryFound = true;
                            }
                        }
                    }
                    if (!coreFound || !memoryFound)
                        throw new InvalidOperationException("Editable P0 graphics/memory domains were not both returned.");
                    return result;
                }
                finally
                {
                    Marshal.FreeHGlobal(buffer);
                }
            }
            finally
            {
                unload();
            }
        }
    }
}
'@ -Language CSharp
}

function Get-MsiNvapiPstateLimits {
    Initialize-MsiNvapiLimitInterop
    $result = [MsiNvapiLimitInteropV1.Reader]::ReadFirstGpuP0Limits()
    return [pscustomobject]@{
        GpuName             = [string]$result.GpuName
        InfoEditable        = [bool]$result.InfoEditable
        CoreEditable        = [bool]$result.CoreEditable
        MemoryEditable      = [bool]$result.MemoryEditable
        CoreValueMHz        = [int]($result.CoreValueKHz / 1000)
        CoreMinimumMHz      = [int][Math]::Ceiling($result.CoreMinimumKHz / 1000.0)
        CoreMaximumMHz      = [int][Math]::Floor($result.CoreMaximumKHz / 1000.0)
        MemoryValueMHz      = [int]($result.MemoryValueKHz / 1000)
        MemoryMinimumMHz    = [int][Math]::Ceiling($result.MemoryMinimumKHz / 1000.0)
        MemoryMaximumMHz    = [int][Math]::Floor($result.MemoryMaximumKHz / 1000.0)
    }
}


