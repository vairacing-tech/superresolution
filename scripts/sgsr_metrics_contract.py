"""Run production metrics/cache logic with a deterministic GL-query test double.

No Gradle, downloaded dependencies, device, or persistent configuration required.
The doubles model only timer queries/config/logging, not rendering correctness.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "common/src/main/java/io/homo/superresolution"

STUBS = {
    "org/slf4j/Logger.java": "package org.slf4j; public interface Logger { default void info(String s,Object... a) {} default void warn(String s,Object... a) {} }",
    "org/slf4j/LoggerFactory.java": "package org.slf4j; public class LoggerFactory { public static Logger getLogger(String s) {return new Logger(){};} }",
    "org/lwjgl/opengl/GL.java": "package org.lwjgl.opengl; public class GL { public static class Caps {public boolean OpenGL33=true;} public static final Caps CAPS=new Caps(); public static Caps getCapabilities(){return CAPS;} }",
    "org/lwjgl/opengl/GL15.java": """package org.lwjgl.opengl;
        public class GL15 {
            public static final int GL_QUERY_RESULT_AVAILABLE=1, GL_QUERY_RESULT=2;
            public static boolean available=false;
            public static boolean failEndOnce=false;
            public static int active, begins, ends, deleted;
            public static void glGenQueries(int[] ids){for(int i=0;i<ids.length;i++)ids[i]=i+1;}
            public static void glDeleteQueries(int[] ids){deleted+=ids.length;}
            public static int glGetQueryObjecti(int id,int name){return available?1:0;}
            public static void glBeginQuery(int type,int id){if(active!=0)throw new AssertionError("nested GPU query");active=id;begins++;}
            public static void glEndQuery(int type){if(failEndOnce){failEndOnce=false;throw new IllegalStateException("end-query failure");}if(active==0)throw new AssertionError("unbalanced GPU query");active=0;ends++;}
        }""",
    "org/lwjgl/opengl/GL33.java": "package org.lwjgl.opengl; public class GL33 {public static final int GL_TIME_ELAPSED=3; public static long glGetQueryObjectui64(int id,int name){return id*1000000L;} }",
    "io/homo/superresolution/common/config/SuperResolutionConfig.java": """package io.homo.superresolution.common.config;
        public class SuperResolutionConfig {
            public static class Algorithm {public String briefName="SGSR1";}
            public static Algorithm getUpscaleAlgorithm(){return new Algorithm();}
            public static boolean isEnableUpscale(){return true;}
            public static double getUpscaleRatio(){return 2;}
        }""",
    "io/homo/superresolution/common/minecraft/handler/RenderHandlerManager.java": """package io.homo.superresolution.common.minecraft.handler;
        public class RenderHandlerManager {
            public static int getRenderWidth(){return 960;} public static int getRenderHeight(){return 540;}
            public static int getScreenWidth(){return 1920;} public static int getScreenHeight(){return 1080;}
        }""",
}

HARNESS = r'''
import io.homo.superresolution.common.metrics.UpscaleGpuMetrics;
import org.lwjgl.opengl.*;
import java.lang.reflect.*;

public class SgsrMetricsContract {
    static final UpscaleGpuMetrics metrics = UpscaleGpuMetrics.getInstance();
    static void check(boolean condition,String message){if(!condition)throw new AssertionError(message);}
    static Object call(Object target,String name,Class<?>[] types,Object... args)throws Exception{
        Method m;
        try {m=target.getClass().getMethod(name,types);}
        catch(NoSuchMethodException e){throw new AssertionError("Missing behavior: "+name,e);}
        return m.invoke(target,args);
    }
    static void start()throws Exception{call(metrics,"beginCpuSubmit",new Class<?>[]{});}
    static void finish(boolean complete)throws Exception{call(metrics,"endCpuSubmit",new Class<?>[]{boolean.class},complete);}
    static boolean transition(int requested,int effective)throws Exception{
        return (boolean)call(metrics,"checkSgsrTransition",new Class<?>[]{int.class,int.class},requested,effective);
    }
    static void ageCpuStart()throws Exception{
        Field f=UpscaleGpuMetrics.class.getDeclaredField("cpuStartTimeNano");f.setAccessible(true);
        f.setLong(metrics,System.nanoTime()-500_000_000L);
    }
    static void seed(){for(int i=0;i<35;i++)metrics.getAggregator().recordGpuSample(1,2);}
    static void reset(boolean supported){
        metrics.destroyGl();metrics.resetForTransition("contract");
        metrics.checkConfigTransition("SGSR1",true,2,960,540,1920,1080);
        GL.CAPS.OpenGL33=supported;GL15.available=false;metrics.initializeGl();
    }
    static void transitions()throws Exception{
        reset(true);transition(7,7);seed();
        check(!transition(7,7),"stable options must retain samples");
        check(metrics.getAggregator().getValidSamples()==5,"stable options erased samples");
        start();metrics.beginUpscale();metrics.endUpscale();finish(true);
        check(metrics.isQuerySlotActive(0),"fixture must contain pending GPU sample");
        check(transition(6,7),"requested toggle must reset even when effective fallback is unchanged");
        check(metrics.getAggregator().getValidSamples()==0,"old samples contaminated new option window");
        check(metrics.getAggregator().getWarmupRemaining()==30,"transition did not restart warmup");
        for(int i=0;i<6;i++)check(!metrics.isQuerySlotActive(i),"old pending query survived transition");
        seed();check(transition(6,3),"effective route change must reset");
        check(metrics.getAggregator().getValidSamples()==0,"old route samples survived");
        seed();check(transition(-1,-1),"disabling SGSR must reset");
        check(metrics.getAggregator().getValidSamples()==0,"disabled SGSR retained samples");
        System.out.println("PASS: stable/requested/effective/disabled transitions and pending query discard");
    }
    static void cpuScope()throws Exception{
        reset(false);start();ageCpuStart();metrics.beginUpscale();metrics.endUpscale();
        check(metrics.getAggregator().getLatestCpuSubmitMs()==0,"CPU recorded before state restoration");
        finish(true);
        check(metrics.getAggregator().getLatestCpuSubmitMs()>=500,"state capture excluded from CPU duration");
        reset(false);start();metrics.beginUpscale();metrics.endUpscale();ageCpuStart();finish(true);
        check(metrics.getAggregator().getLatestCpuSubmitMs()>=500,"state restoration excluded from CPU duration");
        reset(false);start();metrics.beginUpscale();metrics.endUpscale();finish(false);
        check(metrics.getAggregator().getLatestCpuSubmitMs()==0,"failed frame recorded CPU sample");
        System.out.println("PASS: CPU spans state capture/restoration and excludes failed frames");
    }
    static void gpuCorrelation()throws Exception{
        reset(true);seed();
        start();metrics.beginUpscale();metrics.endUpscale();ageCpuStart();finish(true);
        check(metrics.isQuerySlotActive(0),"first query must be pending");
        start();metrics.beginUpscale();metrics.endUpscale();
        check(metrics.getAggregator().getValidSamples()==5,"GPU polled before CPU completion");
        GL15.available=true;finish(true);
        check(metrics.getAggregator().getValidSamples()==7,"both completed queries must be collected");
        check(metrics.getAggregator().getCpuSubmitAvgMs()>=500.0/7,"CPU duration lost slot association");
        Field pending=UpscaleGpuMetrics.class.getDeclaredField("pendingCpuSubmitMs");pending.setAccessible(true);
        double[] cpuSlots=(double[])pending.get(metrics);
        check(cpuSlots[0]>=500 && cpuSlots[1]<500,"outer CPU durations assigned to wrong query slots");
        reset(true);int before=GL15.begins;
        for(int i=0;i<7;i++){start();metrics.beginUpscale();metrics.endUpscale();finish(true);}
        check(GL15.begins-before==6,"full query ring must skip without overwriting");
        check(metrics.getAggregator().getValidSamples()==0,"pending/skipped queries recorded samples");
        check(metrics.getAggregator().getWarmupRemaining()==30,"skips consumed warmup");
        reset(true);start();metrics.beginUpscale();metrics.endUpscale();finish(false);
        check(!metrics.isQuerySlotActive(0),"failed frame left collectible query");
        check(GL15.active==0,"GPU query leaked");
        System.out.println("PASS: correlated GPU slots, nonblocking full ring, failed-frame discard");
    }
    static void viewport()throws Exception{
        Class<?> c;
        try{c=Class.forName("io.homo.superresolution.common.upscale.algo.legacy.sgsr.v1.Sgsr1ViewportCache");}
        catch(ClassNotFoundException e){throw new AssertionError("Missing behavior: SGSR1 viewport upload cache",e);}
        Object cache=c.getConstructor().newInstance();Class<?>[] dims={int.class,int.class};
        check((boolean)call(cache,"beginUpload",dims,960,540),"first frame must upload");
        check((boolean)call(cache,"beginUpload",dims,960,540),"failed/unsubmitted upload must retry");
        call(cache,"uploaded",dims,960,540);
        for(int i=0;i<100;i++)check(!(boolean)call(cache,"beginUpload",dims,960,540),"unchanged viewport reuploaded");
        check((boolean)call(cache,"beginUpload",dims,1280,540),"width change missed");
        check((boolean)call(cache,"beginUpload",dims,960,540),"failed B upload left cached A despite possible UBO mutation");
        check((boolean)call(cache,"beginUpload",dims,960,720),"height change missed");
        call(cache,"uploaded",dims,1280,720);
        check(!(boolean)call(cache,"beginUpload",dims,1280,720),"new viewport not cached");
        call(cache,"invalidate",new Class<?>[]{});
        check((boolean)call(cache,"beginUpload",dims,1280,720),"resource recreation reused old UBO validity");
        System.out.println("PASS: first/stable/resized/failed/recreated viewport uploads");
    }
    static void lifecycle()throws Exception{
        reset(false);start();finish(false);
        check(metrics.getAggregator().getLatestCpuSubmitMs()==0,"failed state capture produced sample");
        metrics.destroyGl();start();metrics.beginUpscale();metrics.endUpscale();finish(true);
        start();metrics.beginUpscale();metrics.endUpscale();finish(true);
        check(metrics.getAggregator().getLatestCpuSubmitMs()>0,"cold initialization never resumes CPU sampling");
        reset(true);seed();start();metrics.beginUpscale();
        metrics.resetForTransition("targets recreated during dispatch");
        check(GL15.active==0,"transition leaked active GL query");
        metrics.endUpscale();finish(true);
        check(metrics.getAggregator().getValidSamples()==0,"recreation accepted stale GPU sample");
        reset(false);start();metrics.beginUpscale();
        metrics.resetForTransition("targets recreated during CPU-only dispatch");
        metrics.endUpscale();finish(true);
        check(metrics.getAggregator().getLatestCpuSubmitMs()==0,"recreation accepted stale CPU-only sample");
        reset(true);start();metrics.beginUpscale();finish(false);
        check(GL15.active==0,"aborted dispatch leaked active query");
        check(!metrics.isQuerySlotActive(0),"aborted dispatch left collectible query");
        reset(true);start();metrics.beginUpscale();GL15.failEndOnce=true;metrics.endUpscale();finish(true);
        check(GL15.active==0,"failed end-query was not cleaned up");
        check(!metrics.isQuerySlotActive(0),"failed end-query became a valid sample");
        reset(false);start();metrics.beginUpscale();metrics.endUpscale();finish(true);
        check(metrics.getF3Line().contains("CPU submit"),"unsupported timer stays in GPU warmup forever");
        reset(false);seed();metrics.checkConfigTransition("SGSR1",true,2,1280,720,1920,1080);
        check(metrics.getAggregator().getValidSamples()==0,"internal resize did not reset");
        seed();metrics.checkConfigTransition("SGSR1",true,2,1280,720,2560,1440);
        check(metrics.getAggregator().getValidSamples()==0,"output resize did not reset");
        reset(true);int deleted=GL15.deleted;
        Field supported=UpscaleGpuMetrics.class.getDeclaredField("gpuTimerSupported");supported.setAccessible(true);
        supported.setBoolean(metrics,false); // Timing disabled after an API failure; objects still exist.
        metrics.destroyGl();
        check(GL15.deleted-deleted==6,"disabled timing leaked allocated query objects");
        System.out.println("PASS: recreation during GPU/CPU-only dispatch, abort, resize and unsupported HUD");
    }
    public static void main(String[] args)throws Exception{
        int failed=0;
        for(String name:new String[]{"transitions","cpuScope","gpuCorrelation","viewport","lifecycle"}){
            try{SgsrMetricsContract.class.getDeclaredMethod(name).invoke(null);}
            catch(InvocationTargetException e){failed++;System.err.println("FAIL "+name+": "+e.getCause());}
        }
        if(failed!=0)throw new AssertionError(failed+" regression groups failed");
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sgsr-contract-") as directory:
    directory = Path(directory)
    sources = []
    for name, contents in {**STUBS, "SgsrMetricsContract.java": HARNESS}.items():
        file = directory / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(contents)
        sources.append(str(file))
    sources += [str(MAIN / "common/metrics" / name) for name in ("MetricsAggregator.java", "UpscaleGpuMetrics.java")]
    cache = MAIN / "common/upscale/algo/legacy/sgsr/v1/Sgsr1ViewportCache.java"
    if cache.exists():
        sources.append(str(cache))
    subprocess.run(["java", "-m", "jdk.compiler/com.sun.tools.javac.Main", "-d", str(directory), *sources], check=True)
    subprocess.run(["java", "-cp", str(directory), "SgsrMetricsContract"], check=True)
