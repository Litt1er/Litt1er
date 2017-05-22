//
//  ViewController.m
//  litt1er
//
//  Created by litt1er on 17/5/8.
//  Copyright © 2017年 范朝玉. All rights reserved.
//

#import "ViewController.h"
#import "Litt1erPro.h"
#import "TestObject.h"
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
    
//    UIWebView *webView = [[UIWebView alloc] initWithFrame:CGRectMake(20, 20, 200, 200)];
//    webView.backgroundColor = [UIColor cyanColor];
//    [self.view addSubview:webView];
//
//    self.web = webView;
//    id arr = @[@"1"];
//    NSArray *testArr = Litt1erTest(arr);
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil message:@"账号或密码不正确" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSLog(@"aaa");
    }];
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"找回密码" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSLog(@"bbb");
        }];
    [alertController addAction:cancelAction];
    [alertController addAction:confirmAction];
    [self presentViewController:alertController animated:YES completion:nil];
    

    
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
//    NSMutableString *name = [NSMutableString stringWithFormat:@"aaa"];
//    NSMutableString *name = [[NSMutableString alloc] initWithString:@"aaa"];
//
//    TestObject *test = [[TestObject alloc] init];
//    test.name = name;
//    NSLog(@"%p%p1---------------%@,   %p",name,test.name,test.name,test);
//   [name appendString:@"bbb"];
////    [name stringByAppendingString:@"22"];
////    test.name = name;
//    NSLog(@"%p%p2---------------%@,   %p",name,test.name,test.name,test);
//    NSString *name = @"aaaa";
//    NSLog(@"%p",name);
//    name = @"abbbb";
//    NSLog(@"%p",name);
    
//    NSMutableString *name = [NSMutableString stringWithFormat:@"aaa"];
//    NSLog(@"111-----%@    %p",[name valueForKey:@"retainCount"],name);
//    NSString *test = [name copy];
//    NSLog(@"222-----%@    %p",[name valueForKey:@"retainCount"],test);
//    
//    NSString *st1 = [NSString stringWithFormat:@"st1"];
//    NSArray *a1 = [NSArray arrayWithObjects:st1, nil];
//    NSLog(@"a1-----%@    %p",[a1 valueForKey:@"retainCount"],a1);
//    NSArray *a2 = [a1 copy];
//    NSLog(@"a2-----%@    %p",[a1 valueForKey:@"retainCount"],a1);
//
//
//    NSMutableArray *arr = [[NSMutableArray alloc] init];
//    [arr addObject:[[NSMutableString alloc]initWithString:@"value1"]];
//    [arr addObject:[[NSMutableString alloc]initWithString:@"value2"]];
//    NSLog(@"111-----%@    %p",[arr valueForKey:@"retainCount"],arr);
//    NSArray *array = [arr copy];
//    NSLog(@"222-----%@    %p",[arr valueForKey:@"retainCount"],array);
//    
//    
//    NSString *str = @"sss";
//    NSLog(@"str-----%@    %p",[str valueForKey:@"retainCount"],str);
//    NSMutableString *ss = [str mutableCopy];
//    [ss appendString:@"bbb"];
    
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:nil message:@"账号或密码不正确" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSLog(@"aaa");
    }];
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"找回密码" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSLog(@"bbb");
    }];
    [alertController addAction:cancelAction];
    [alertController addAction:confirmAction];
    [self presentViewController:alertController animated:YES completion:nil];
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
