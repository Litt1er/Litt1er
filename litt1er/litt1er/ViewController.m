//
//  ViewController.m
//  litt1er
//
//  Created by litt1er on 17/5/8.
//  Copyright © 2017年 范朝玉. All rights reserved.
//

#import "ViewController.h"
#import "Litt1erPro.h"
@interface ViewController ()<Litt1erPro>
@property (nonatomic, strong) UIWebView *web;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.

//    
//    void (^block)() = nil;
//    
//    sleep(10);
//    block = ^{
//        NSLog(@"1");
//    };
//    block();
    
    UIWebView *webView = [[UIWebView alloc] initWithFrame:CGRectMake(20, 20, 200, 200)];
    webView.backgroundColor = [UIColor cyanColor];
    [self.view addSubview:webView];

    self.web = webView;
    id arr = @[@"1"];
    NSArray *testArr = Litt1erTest(arr);
}

- (void)litt1er
{
    NSLog(@"litt1er");
}

NSArray * Litt1erTest (NSDictionary *test){
    if ([test isKindOfClass:[NSArray class]]) {
        NSLog(@"1111");
    }else{
        NSLog(@"22222");
    }
    return nil;
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


@end
