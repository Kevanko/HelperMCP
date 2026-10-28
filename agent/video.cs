namespace F__BUILD__ {
using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public sealed class MfEncoder : IDisposable {
 [DllImport("mfplat.dll")]static extern int MFStartup(uint version,uint flags);
 [DllImport("mfplat.dll")]static extern int MFShutdown();
 [DllImport("mfplat.dll")]static extern int MFCreateMediaType(out IntPtr type);
 [DllImport("mfplat.dll")]static extern int MFCreateSample(out IntPtr sample);
 [DllImport("mfplat.dll")]static extern int MFCreateMemoryBuffer(uint size,out IntPtr buffer);
 [DllImport("ole32.dll")]static extern int CoCreateInstance(ref Guid clsid,IntPtr outer,uint clsctx,ref Guid iid,out IntPtr instance);
 [DllImport("ole32.dll")]static extern int CoInitializeEx(IntPtr reserved,uint mode);
 [DllImport("ole32.dll")]static extern void CoUninitialize();
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int SetGuid(IntPtr self,ref Guid key,ref Guid value);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int SetU32(IntPtr self,ref Guid key,uint value);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int SetU64(IntPtr self,ref Guid key,ulong value);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int CodecValue(IntPtr self,ref Guid key,IntPtr value);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int GetPointer(IntPtr self,out IntPtr value);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int SetType(IntPtr self,uint stream,IntPtr type,uint flags);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int Message(IntPtr self,uint message,IntPtr param);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int ProcessInput(IntPtr self,uint stream,IntPtr sample,uint flags);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int ProcessOutput(IntPtr self,uint flags,uint count,ref OutputBuffer output,out uint status);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int OutputInfo(IntPtr self,uint stream,out StreamInfo info);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int SampleBuffer(IntPtr self,IntPtr buffer);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int SampleTime(IntPtr self,long time);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int BufferLock(IntPtr self,out IntPtr data,out uint capacity,out uint current);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int BufferUnlock(IntPtr self);
 [UnmanagedFunctionPointer(CallingConvention.StdCall)]delegate int BufferLength(IntPtr self,uint current);
 [StructLayout(LayoutKind.Sequential)]struct OutputBuffer {public uint Stream;public IntPtr Sample;public uint Status;public IntPtr Events;}
 [StructLayout(LayoutKind.Sequential)]struct StreamInfo {public uint Flags,Size,Alignment;}
 static T Fn<T>(IntPtr obj,int slot){return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj),slot*IntPtr.Size),typeof(T));}
 static void Check(int hr){Marshal.ThrowExceptionForHR(hr);}
 static Guid Id(string s){return new Guid(s);}
 static void GuidAttr(IntPtr type,string key,string value){Guid k=Id(key),v=Id(value);Check(Fn<SetGuid>(type,24)(type,ref k,ref v));}
 static void U32(IntPtr type,string key,uint value){Guid k=Id(key);Check(Fn<SetU32>(type,21)(type,ref k,value));}
 static void U64(IntPtr type,string key,ulong value){Guid k=Id(key);Check(Fn<SetU64>(type,22)(type,ref k,value));}
 const string Major="48eba18e-f8c9-4687-bf11-0a74c9f96a8f",Subtype="f7e34c9a-42e8-4714-b74b-cb29d72c35e5",Video="73646976-0000-0010-8000-00aa00389b71";
 IntPtr transform;bool started,comStarted;readonly int w,h,fps;uint outputSize;long next;
 byte[] converted;
 bool CodecUInt(string name,uint value){IntPtr api=IntPtr.Zero,variant=IntPtr.Zero;try{Guid iid=Id("901db4c7-31ce-41a2-85dc-8fa0bf41b8da");if(Marshal.QueryInterface(transform,ref iid,out api)<0)return false;
  variant=Marshal.AllocHGlobal(32);for(int i=0;i<32;i++)Marshal.WriteByte(variant,i,0);Marshal.WriteInt16(variant,19);Marshal.WriteInt32(variant,8,unchecked((int)value));Guid property=Id(name);return Fn<CodecValue>(api,9)(api,ref property,variant)==0;
 }finally{if(variant!=IntPtr.Zero)Marshal.FreeHGlobal(variant);if(api!=IntPtr.Zero)Marshal.Release(api);}}
 public bool ForceKeyFrame(){return CodecUInt("398c1b98-8353-475a-9ef2-8f265d260345",1);}
 public List<byte[]> EncodeRgb(int[] rgb){
  if(rgb==null||rgb.Length!=w*h)throw new ArgumentException("Wrong RGB size");if(converted==null)converted=new byte[w*h*3/2];int plane=w*h;
  for(int y=0;y<h;y+=2)for(int x=0;x<w;x+=2){int su=0,sv=0;
   for(int dy=0;dy<2;dy++)for(int dx=0;dx<2;dx++){int offset=(y+dy)*w+x+dx,p=rgb[offset],r=(p>>16)&255,g=(p>>8)&255,b=p&255;
    converted[offset]=(byte)(((66*r+129*g+25*b+128)>>8)+16);su+=((-38*r-74*g+112*b+128)>>8)+128;sv+=((112*r-94*g-18*b+128)>>8)+128;}
   int chroma=plane+(y/2)*w+x;converted[chroma]=(byte)((su+2)/4);converted[chroma+1]=(byte)((sv+2)/4);
  }return Encode(converted);
 }
 public MfEncoder(int width,int height,int fps,int bitrate){this.w=width;this.h=height;this.fps=fps;
  if(width<16||height<16||width%2!=0||height%2!=0||width>4096||height>4096||fps<1||fps>60)throw new ArgumentOutOfRangeException();
  IntPtr input=IntPtr.Zero,output=IntPtr.Zero,attrs=IntPtr.Zero;
  try{int init=CoInitializeEx(IntPtr.Zero,0);if(init>=0)comStarted=true;else if(init!=unchecked((int)0x80010106))Check(init);Check(MFStartup(0x20070,0));started=true;Guid cls=Id("6ca50344-051a-4ded-9779-a43305165e35"),iid=Id("bf94c121-5b05-4e6f-8000-ba598961414d");Check(CoCreateInstance(ref cls,IntPtr.Zero,1,ref iid,out transform));
   if(Fn<GetPointer>(transform,8)(transform,out attrs)>=0){U32(attrs,"9c27891a-ed7a-40e1-88e8-b22727a024ee",1);}
   Check(MFCreateMediaType(out output));Common(output,"34363248-0000-0010-8000-00aa00389b71");U32(output,"20332624-fb0d-4d9e-bd0d-cbf6786c102e",(uint)bitrate);U32(output,"ad76a80b-2d5c-4e0b-b375-64e520137036",66);Check(Fn<SetType>(transform,16)(transform,0,output,0));
   Check(MFCreateMediaType(out input));Common(input,"3231564e-0000-0010-8000-00aa00389b71");Check(Fn<SetType>(transform,15)(transform,0,input,0));
   CodecUInt("95f31b26-95a4-41aa-9303-246a7fc6eef1",60);
   StreamInfo si;Check(Fn<OutputInfo>(transform,7)(transform,0,out si));outputSize=Math.Max(si.Size,(uint)(w*h*2));if((si.Flags&0x100)!=0)throw new NotSupportedException("Encoder supplies output samples");
   Check(Fn<Message>(transform,23)(transform,0x10000000,IntPtr.Zero));Check(Fn<Message>(transform,23)(transform,0x10000003,IntPtr.Zero));
  }catch{Dispose();throw;}finally{foreach(var p in new[]{attrs,input,output})if(p!=IntPtr.Zero)Marshal.Release(p);}
 }
 void Common(IntPtr type,string subtype){GuidAttr(type,Major,Video);GuidAttr(type,Subtype,subtype);U64(type,"1652c33d-d6b2-4012-b834-72030849a37d",((ulong)w<<32)|(uint)h);U64(type,"c459a2e8-3d2c-4e44-b132-fee5156c7bb0",((ulong)fps<<32)|1);U32(type,"e2724bb8-e676-4806-b4b2-a8d6efb44ccd",2);}
 IntPtr Sample(byte[] bytes,uint capacity,out IntPtr buffer){IntPtr sample=IntPtr.Zero;buffer=IntPtr.Zero;try{Check(MFCreateSample(out sample));Check(MFCreateMemoryBuffer(capacity,out buffer));
  if(bytes!=null){IntPtr data;uint max,current;Check(Fn<BufferLock>(buffer,3)(buffer,out data,out max,out current));try{Marshal.Copy(bytes,0,data,bytes.Length);}finally{Check(Fn<BufferUnlock>(buffer,4)(buffer));}Check(Fn<BufferLength>(buffer,6)(buffer,(uint)bytes.Length));}
  Check(Fn<SampleBuffer>(sample,42)(sample,buffer));return sample;
 }catch{if(sample!=IntPtr.Zero)Marshal.Release(sample);if(buffer!=IntPtr.Zero)Marshal.Release(buffer);buffer=IntPtr.Zero;throw;}}
 public List<byte[]> Encode(byte[] nv12){if(nv12.Length!=w*h*3/2)throw new ArgumentException("Wrong NV12 size");IntPtr buffer,sample=Sample(nv12,(uint)nv12.Length,out buffer);try{long duration=10000000/fps;Check(Fn<SampleTime>(sample,36)(sample,next));Check(Fn<SampleTime>(sample,38)(sample,duration));Check(Fn<ProcessInput>(transform,24)(transform,0,sample,0));next+=duration;}finally{Marshal.Release(sample);Marshal.Release(buffer);}return Drain();}
 public List<byte[]> Drain(){var frames=new List<byte[]>();for(int i=0;i<32;i++){IntPtr buffer,sample=Sample(null,outputSize,out buffer);var output=new OutputBuffer{Stream=0,Sample=sample};
  try{uint status;int hr=Fn<ProcessOutput>(transform,25)(transform,0,1,ref output,out status);if(hr==unchecked((int)0xC00D6D72))break;Check(hr);
   IntPtr contiguous;Check(Fn<GetPointer>(sample,41)(sample,out contiguous));try{IntPtr data;uint max,length;Check(Fn<BufferLock>(contiguous,3)(contiguous,out data,out max,out length));try{if(length>16000000)throw new InvalidOperationException("Encoder output too large");var bytes=new byte[length];Marshal.Copy(data,bytes,0,bytes.Length);frames.Add(bytes);}finally{Check(Fn<BufferUnlock>(contiguous,4)(contiguous));}}finally{Marshal.Release(contiguous);}
  }finally{if(output.Events!=IntPtr.Zero)Marshal.Release(output.Events);Marshal.Release(sample);Marshal.Release(buffer);}}
  return frames;
 }
 public List<byte[]> Finish(){Check(Fn<Message>(transform,23)(transform,0x10000002,IntPtr.Zero));Check(Fn<Message>(transform,23)(transform,1,IntPtr.Zero));return Drain();}
 public void Dispose(){if(transform!=IntPtr.Zero){Marshal.Release(transform);transform=IntPtr.Zero;}if(started){MFShutdown();started=false;}if(comStarted){CoUninitialize();comStarted=false;}}

}
}
