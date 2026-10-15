#import <Cocoa/Cocoa.h>
extern int SLSMainConnectionID(void);
extern CGError SLSFindWindowAndOwner(int,uint32_t,int,int,CGPoint*,CGPoint*,uint32_t*,int*);
extern CGError SLSConnectionGetPID(int,pid_t*);
int main(int argc,char**argv) { @autoreleasepool {
 CGPoint p=CGPointMake(argc>1?atof(argv[1]):1000,argc>2?atof(argv[2]):195),local;
 uint32_t wid=0;int owner=0;pid_t pid=0;
 for(int i=0;i<8;i++) { uint32_t prev=wid; CGError err=SLSFindWindowAndOwner(SLSMainConnectionID(),prev,i?-1:1,0,&p,&local,&wid,&owner); SLSConnectionGetPID(owner,&pid); printf("%d id=%u pid=%d local=%.1f,%.1f error=%d\n",i,wid,pid,local.x,local.y,err); if(!wid||wid==prev)break; }
} }
