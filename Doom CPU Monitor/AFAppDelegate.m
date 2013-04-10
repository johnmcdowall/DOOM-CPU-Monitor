//
//  AFAppDelegate.m
//  Doom CPU Monitor
//
//  Created by Ash Furrow on 2013-03-14.
//  Copyright (c) 2013 Ash Furrow. All rights reserved.
//

#include <sys/sysctl.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/mach_host.h>

#import <ReactiveCocoa.h>
#import <EXTScope.h>

#import "AFAppDelegate.h"

#define kDefaultFaceKey @"com.ashFurrow.DefaultFace"

@interface AFAppDelegate ()

@property (strong) NSLock *CPUUsageLock;

@property (nonatomic, strong) NSDictionary *faceChoices;
@property (nonatomic, strong) NSString *currentFace;

@end

static const NSUInteger kMaxDangerLevel = 6;

@implementation AFAppDelegate
{
    processor_info_array_t prevCpuInfo;
    processor_info_array_t cpuInfo;
    mach_msg_type_number_t numCpuInfo, numPrevCpuInfo;
    unsigned numCPUs;
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification
{
	[self setupMenu];
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSString *defaultFace = [defaults valueForKey:kDefaultFaceKey];
	if (defaultFace && [[self.faceChoices allKeys] containsObject:defaultFace])
	{
		self.currentFace = defaultFace;
	}
	else
	{
		self.currentFace = @"Doom";
		[defaults setValue:self.currentFace forKey:kDefaultFaceKey];
		[defaults synchronize];
	}
	
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    
	[self.statusItem setupView];
    [self.statusItem setHighlightMode:YES];
    [self.statusItem setMenu:self.statusMenu];
    
    [self setDangerLevel:1];
    
    self.CPUUsageLock = [[NSLock alloc] init];
    
    int mib[2U] = { CTL_HW, HW_NCPU };
    size_t sizeOfNumCPUs = sizeof(numCPUs);
    int status = sysctl(mib, 2U, &numCPUs, &sizeOfNumCPUs, NULL, 0U);
    if(status) numCPUs = 1;
    
    @weakify(self);
    [RACAble(self.dangerLevel) subscribeNext:^(id x) {
        @strongify(self);
        NSString *facePath = [[self.faceChoices[self.currentFace] stringByAppendingPathComponent:[@(self.dangerLevel) stringValue]] stringByAppendingPathExtension:@"png"];
        NSImage *image = [[NSImage alloc] initWithContentsOfFile:facePath];
        [self.statusItem setImage:image];
        [self.statusItem setAlternateImage:image];
    }];
    
    [[RACSignal interval:1] subscribeNext:^(id x) {
        @strongify(self);
        CGFloat highestValue = -1;
        natural_t numCPUsU = 0U;
        kern_return_t err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo);
        if(err == KERN_SUCCESS) {
            [self.CPUUsageLock lock];
            
            for(unsigned i = 0U; i < numCPUs; ++i) {
                float inUse, total;
                if(prevCpuInfo) {
                    inUse = (
                             (cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER]   - prevCpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER])
                             + (cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM] - prevCpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM])
                             + (cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE]   - prevCpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE])
                             );
                    total = inUse + (cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE] - prevCpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE]);
                } else {
                    inUse = cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_USER] + cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_SYSTEM] + cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_NICE];
                    total = inUse + cpuInfo[(CPU_STATE_MAX * i) + CPU_STATE_IDLE];
                }
                
                CGFloat usage = inUse/total;
                if (highestValue < usage) highestValue = usage;
                
                NSLog(@"Core: %u Usage: %f", i, usage);
            }
            [self.CPUUsageLock unlock];
            
            if(prevCpuInfo) {
                size_t prevCpuInfoSize = sizeof(integer_t) * numPrevCpuInfo;
                vm_deallocate(mach_task_self(), (vm_address_t)prevCpuInfo, prevCpuInfoSize);
            }
            
            prevCpuInfo = cpuInfo;
            numPrevCpuInfo = numCpuInfo;
            
            cpuInfo = NULL;
            numCpuInfo = 0U;
        } else {
            NSLog(@"Error!");
            [NSApp terminate:nil];
        }
        
        [self setDangerLevel:(highestValue * (kMaxDangerLevel - 1)) + 1];
        
        NSLog(@"Highest Core Usage: %f", highestValue);
    }];
}

#pragma mark - Private Methods
- (void)setupMenu
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSURL *appSupport = [[fileManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil] URLByAppendingPathComponent:@"Doom CPU/Faces"];

	//Create our dir if it doesnt exist
	BOOL isDir;
	if (![fileManager fileExistsAtPath:appSupport.path isDirectory:&isDir] || !isDir)
	{
		[fileManager createDirectoryAtURL:appSupport withIntermediateDirectories:YES attributes:nil error:nil];
		[self createDoomItem];
	}
	
	NSDirectoryEnumerator *dirEnumerator = [fileManager enumeratorAtURL:appSupport includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:NSDirectoryEnumerationSkipsSubdirectoryDescendants|NSDirectoryEnumerationSkipsHiddenFiles errorHandler:NULL];
	
	//We start at 2 to account for the about item and the seperator
	NSInteger itemIndex = 2;
	NSMutableDictionary *items = [NSMutableDictionary dictionary];
	for (NSURL *faceURL in dirEnumerator)
	{
		// Retrieve the file name. From NSURLNameKey, cached during the enumeration.
        NSString *fileName;
        [faceURL getResourceValue:&fileName forKey:NSURLNameKey error:NULL];
		
		// Add the item
		items[fileName] = faceURL.path;
		
		//Create Menu Item
		NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:fileName action:@selector(selectItem:) keyEquivalent:@""];
		[self.statusMenu insertItem:item atIndex:itemIndex++];
	}

	self.faceChoices = items;
}

// This creates the Doom item in application support if it is not present
- (void)createDoomItem
{
	NSFileManager *fileManager = [NSFileManager defaultManager];
	NSURL *doomFace = [fileManager URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:nil];
	doomFace = [doomFace URLByAppendingPathComponent:@"Doom CPU/Faces/Doom/"];
	
	if ([fileManager createDirectoryAtURL:doomFace withIntermediateDirectories:YES attributes:nil error:nil])
	{		
		NSBundle *bundle = [NSBundle mainBundle];
		for (NSInteger i = 1 ; i <= 6; i++)
		{
			NSURL *face = [bundle URLForResource:[@(i) stringValue] withExtension:@"png" subdirectory:nil];
			NSURL *newFace = [[doomFace URLByAppendingPathComponent:[@(i) stringValue]] URLByAppendingPathExtension:@"png"];
			[fileManager copyItemAtURL:face toURL:newFace error:nil];
		}
	}
}

#pragma mark - NSMenuDelegate methods
- (void)selectItem:(NSMenuItem *)item
{
	self.currentFace = item.title;
	[self setDangerLevel:_dangerLevel];
	
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setValue:self.currentFace forKey:kDefaultFaceKey];
	[defaults synchronize];
}

@end
