/* Compiles the production tab-target constructor with a minimal window model.
 * The reference retains the former repeated member scan. */
#import <Cocoa/Cocoa.h>
#include <assert.h>
#include <stdio.h>

struct application { pid_t pid; };
struct window { uint32_t id; struct application *application; uint64_t strip_column; };

#define HWM_FEEDBACK_TAB_HARNESS 1
#include "../src/strip_feedback.m"

static NSMutableArray *title_calls;
static NSString *hwm_feedback_title(struct window *window,double now)
{
    (void)now;
    [title_calls addObject:@(window->id)];
    return [NSString stringWithFormat:@"title-%u",window->id];
}

static NSDictionary *target(struct window *member,struct window *active,CGRect shown,CGRect screen,double y,NSUInteger index,NSUInteger count)
{
    double gap=4, width=(shown.size.width-gap*(count-1))/fmax(1,count), top=shown.origin.y-y;
    CGRect rect=CGRectMake(shown.origin.x-screen.origin.x+index*(width+gap),top-screen.origin.y,width,y-6);
    return @{@"id":@(member->id),@"pid":@(member->application->pid),@"column":@(member->strip_column),@"rect":[NSValue valueWithRect:rect],
             @"title":[NSString stringWithFormat:@"title-%u",member->id],@"active":@(member==active)};
}

static NSArray *reference(NSArray *windows,NSSet *tabbed,NSDictionary *active,CGRect shown,CGRect screen,double y)
{
    NSMutableArray *result=[NSMutableArray array];
    for(NSValue *value in windows) {
        struct window *window=[value pointerValue];
        if(![tabbed containsObject:@(window->strip_column)] || active[@(window->strip_column)]!=value) continue;
        NSMutableArray *members=[NSMutableArray array];
        for(NSValue *other in windows) if(((struct window *)[other pointerValue])->strip_column==window->strip_column) [members addObject:other];
        for(NSUInteger i=0;i<members.count;i++) [result addObject:target([members[i] pointerValue],window,shown,screen,y,i,members.count)];
    }
    return result;
}

static NSArray *production(NSArray *windows,NSSet *tabbed,NSDictionary *active,CGRect shown,CGRect screen,double y)
{
    NSMutableDictionary *members=[NSMutableDictionary dictionary];
    for(NSValue *value in windows) {
        struct window *window=[value pointerValue];
        NSNumber *column=@(window->strip_column);
        if([tabbed containsObject:column]) {
            NSMutableArray *group=members[column];
            if(!group) { group=[NSMutableArray array]; members[column]=group; }
            [group addObject:value];
        }
    }
    NSMutableArray *result=[NSMutableArray array];
    for(NSValue *value in windows) {
        struct window *window=[value pointerValue];
        NSNumber *column=@(window->strip_column);
        if([tabbed containsObject:column] && active[column]==value)
            hwm_feedback_append_tab_targets(result,members[column],window,shown,screen,y,17.25);
    }
    return result;
}

static void check_case(struct window *raw,NSUInteger count,NSArray *order,NSSet *tabbed,NSDictionary *active,CGRect shown,CGRect screen,double y)
{
    (void)raw;
    NSArray *expected=reference(order,tabbed,active,shown,screen,y);
    [title_calls removeAllObjects];
    NSArray *actual=production(order,tabbed,active,shown,screen,y);
    assert([actual isEqualToArray:expected]);
    NSMutableArray *titleOrder=[NSMutableArray array];
    for(NSDictionary *entry in expected) [titleOrder addObject:entry[@"id"]];
    assert([title_calls isEqualToArray:titleOrder]);
    (void)count;
}

static void equivalence(void)
{
    struct application apps[12]; struct window raw[12];
    for(NSUInteger i=0;i<12;i++) { apps[i]=(struct application){.pid=(pid_t)(100+i)}; raw[i]=(struct window){.id=(uint32_t)(i+1),.application=&apps[i],.strip_column=(i*7)%5+1}; }
    NSArray *normal=@[[NSValue valueWithPointer:&raw[4]],[NSValue valueWithPointer:&raw[0]],[NSValue valueWithPointer:&raw[9]],
                      [NSValue valueWithPointer:&raw[2]],[NSValue valueWithPointer:&raw[11]],[NSValue valueWithPointer:&raw[1]],
                      [NSValue valueWithPointer:&raw[7]],[NSValue valueWithPointer:&raw[3]],[NSValue valueWithPointer:&raw[10]],
                      [NSValue valueWithPointer:&raw[5]],[NSValue valueWithPointer:&raw[8]],[NSValue valueWithPointer:&raw[6]]];
    for(NSUInteger shift=0;shift<12;shift++) {
        NSMutableArray *order=[NSMutableArray array];
        for(NSUInteger i=0;i<normal.count;i++) [order addObject:normal[(i+shift)%normal.count]];
        NSSet *tabbed=[NSSet setWithArray:@[@1,@3,@5]];
        NSMutableDictionary *active=[NSMutableDictionary dictionary];
        for(NSValue *value in order) { struct window *window=[value pointerValue]; if([tabbed containsObject:@(window->strip_column)] && !active[@(window->strip_column)]) active[@(window->strip_column)]=value; }
        check_case(raw,12,order,tabbed,active,CGRectMake(125+shift,80,701-shift*3,600),CGRectMake(40,20,1440,900),30+shift%3);
    }
}

static double seconds(void) { return NSProcessInfo.processInfo.systemUptime; }
static void benchmark(void)
{
    enum { count=256, rounds=300 };
    struct application apps[count]; struct window raw[count]; NSMutableArray *order=[NSMutableArray array];
    NSMutableDictionary *active=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<count;i++) { apps[i]=(struct application){.pid=(pid_t)i}; raw[i]=(struct window){.id=(uint32_t)(i+1),.application=&apps[i],.strip_column=i/2+1}; NSValue *value=[NSValue valueWithPointer:&raw[i]]; [order addObject:value]; if(!(i&1)) active[@(raw[i].strip_column)]=value; }
    NSMutableSet *tabbed=[NSMutableSet set]; for(NSUInteger i=1;i<=count/2;i++) [tabbed addObject:@(i)];
    CGRect shown=CGRectMake(10,20,1000,600), screen=CGRectMake(0,0,1440,900);
    NSArray *expected=reference(order,tabbed,active,shown,screen,30);
    [title_calls removeAllObjects];
    assert([production(order,tabbed,active,shown,screen,30) isEqualToArray:expected]);
    double began=seconds(); for(int i=0;i<rounds;i++) @autoreleasepool { (void)reference(order,tabbed,active,shown,screen,30); } double old=seconds()-began;
    began=seconds(); for(int i=0;i<rounds;i++) @autoreleasepool { [title_calls removeAllObjects]; (void)production(order,tabbed,active,shown,screen,30); } double grouped=seconds()-began;
    printf("feedback snapshot equivalence: 12 mixed-order cases passed\n");
    printf("reference member comparisons/tick: %u; grouped window visits/tick: %u\n",count*(count/2),count*2);
    printf("compiled snapshot benchmark: reference %.6fs; grouped %.6fs; speedup %.2fx\n",old,grouped,old/grouped);
}

int main(void)
{
    @autoreleasepool { title_calls=[NSMutableArray new]; equivalence(); benchmark(); [title_calls release]; }
    return 0;
}
