//
//  SHHHomeNavigationController.m
//  SHHFrameWorkWithNaviAndTabBar
//
//  Created by sui huan on 12-9-6.
//  Copyright (c) 2012年 sui huan. All rights reserved.
//

#import "SHHHomeNavigationController.h"
#import "SHHHomeViewController.h"
#import "MainContactViewController.h"
//#import "ProjectApplication.h"
#import "testViewController.h"
#import "MainViewController.h"
#import "DetailViewController.h"
@implementation SHHHomeNavigationController

- (id)init
{
    self = [super init];
    if (self)
    {
        // 设置tabbar未选中图片
        self.tabBarItem.title = @"首页";
        self.tabBarItem.image = [UIImage imageNamed:@"recomment"];
        self.tabBarItem.badgeValue = @"1";
        self.delegate = self;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    if (homeViewController_)
        return;
	
//    homeViewController_ = [[SHHHomeViewController alloc] init];
//    homeViewController_.view.frame =CGRectMake(0,0,self.view.frame.size.width,self.view.frame.size.height+200);
    // 设置导航根视图

    homeViewController_ =    [[MainContactViewController alloc] initWithNibName:@"MainContactViewController" bundle:nil];
    
    MainViewController *controller =  [[MainViewController alloc] initWithNibName:@"MainViewController" bundle:nil];
    
//    DetailViewController *controller1 =  [[DetailViewController alloc] initWithNibName:@"DetailViewController" bundle:nil];

    [self pushViewController:controller animated:NO];
}

- (void) viewWillAppear:(BOOL)animated
{
    // 设置导航栏背景颜色
    if ([self.navigationBar respondsToSelector:@selector(setBackgroundImage:forBarMetrics:)])
    {
        [self.navigationBar setBackgroundImage:[UIImage imageNamed:@"bgCartNavi"] forBarMetrics:UIBarMetricsDefault];
    }
    else
    {
        [self.navigationBar setBackgroundImage:[UIImage imageNamed:@"bgCartNavi"]];
    }
}

- (void) dealloc
{
    [homeViewController_ release];
    [super dealloc];
}


@end
