//
//  TestObject.m
//  litt1er
//
//  Created by litt1er on 17/5/12.
//  Copyright © 2017年 范朝玉. All rights reserved.
//

#import "TestObject.h"

@implementation TestObject

- (id)copyWithZone:(nullable NSZone *)zone
{
    TestObject *object = [[TestObject alloc] init];
    object.name = self.name;
    return object;
}

- (void)setName:(NSString *)name
{
//    _name = name;
    _name = [name copy];
    NSLog(@"%p%p",_name,name);
}
@end
