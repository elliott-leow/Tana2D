#include <assert.h>
#include <math.h>
#include <stdio.h>
#include "../src/plane_pan_resample.h"

static void constant_velocity(double reports,double frames)
{
    HWMPanResampler r={0}; double next=0,old_held=0,old_out=0,held_error=0,out_error=0; int measured=0;
    for(int frame=0;frame<240;frame++) {
        double t=(frame+.37)/frames;
        while(next<=t) { assert(hwm_pan_resample_add(&r,next,300*next,-80*next)); next+=1/reports; }
        HWMPanPosition p=hwm_pan_resample_at(&r,t,1/frames);
        double held=r.samples[r.count-1].x;
        if(frame>10) {
            double ideal=300/frames;
            held_error+=pow((held-old_held)-ideal,2);
            out_error+=pow((p.x-old_out)-ideal,2); measured++;
            assert(fabs(p.x-300*t)<1e-6 && fabs(p.y+80*t)<1e-6);
        }
        old_held=held; old_out=p.x;
    }
    assert(measured>0 && out_error<held_error*0.01+1e-12);
}
int main(void)
{
    const double rates[]={80,125,240,300,500};
    for(unsigned i=0;i<sizeof(rates)/sizeof(*rates);i++) { constant_velocity(rates[i],60); constant_velocity(rates[i],120); }
    HWMPanResampler r={0};
    assert(hwm_pan_resample_add(&r,1,0,0)); assert(hwm_pan_resample_add(&r,1.005,5,0));
    assert(hwm_pan_resample_add(&r,1.01,10,0));
    assert(hwm_pan_resample_at(&r,1.02,1.0/60).x==10); /* bunched startup */
    assert(hwm_pan_resample_add(&r,1.015,15,0));
    assert(!hwm_pan_resample_add(&r,1.005,100,100));
    assert(hwm_pan_resample_at(&r,1.02,1.0/60).x>15);
    assert(hwm_pan_resample_add(&r,1.02,14,0));
    HWMPanPosition reversed=hwm_pan_resample_at(&r,1.03,1.0/60);
    assert(reversed.x==14 && reversed.y==0);
    assert(hwm_pan_resample_add(&r,1.03,14,0));
    assert(hwm_pan_resample_at(&r,1.04,1.0/60).x==14);
    assert(hwm_pan_resample_at(&r,1.2,1.0/60).x==14);
    hwm_pan_resample_reset(&r); assert(r.count==0);
    /* Future vsync: 8 ms old report plus one 60 Hz refresh is >20 ms. */
    for(int i=0;i<6;i++) assert(hwm_pan_resample_add(&r,2+i*.008,1000000+100*i*.008,-1000000-25*i*.008));
    double target=2+.040+.008+1.0/60;
    HWMPanPosition future=hwm_pan_resample_at(&r,target,1.0/60);
    assert(fabs(future.x-(1000000+100*(target-2)))<1e-6);
    assert(fabs(future.y-(-1000000-25*(target-2)))<1e-6);
    /* A tiny sideways sign change must not discard history on a straight pan. */
    hwm_pan_resample_reset(&r);
    assert(hwm_pan_resample_add(&r,3,0,0));
    assert(hwm_pan_resample_add(&r,3.01,10,.001));
    assert(hwm_pan_resample_add(&r,3.02,20,0));
    assert(r.count==3 && hwm_pan_resample_at(&r,3.03,1.0/60).x>20);
    puts("plane_pan_resample_test: OK");
}
