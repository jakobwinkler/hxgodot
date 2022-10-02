package godot.macros;

import haxe.macro.Context;
import haxe.macro.Expr;
import godot.macros.TypeMacros;

using StringTools;

enum FunctionBindType {
    CONSTRUCTOR(index:Int);
    DESTRUCTOR;
    METHOD;
    STATIC_FUNCTION;
    OPERATOR;
}

@:structInit
class ClassContext {
    public var name:String;
    @:optional public var abstractName:String;
    public var type:Int;
    public var typePath:TypePath;
}

@:structInit
class FunctionArgument {
    public var name:String;
    public var type:TypePath;
    @:optional public var defaultValue:Dynamic;
}

@:structInit
class FunctionBind {
    public var clazz:ClassContext;
    public var name:String;
    public var type:FunctionBindType;
    public var returnType:TypePath;
    public var access:Array<Access>;
    public var arguments:Array<FunctionArgument>;
    public var macros:{
        field:Field,
        fieldSetter:String
    };
}

class FunctionMacros {
    //
    public static function buildConstructorWithAbstract(
        _bind:FunctionBind,
        _index:Int, 
        _fields:Array<Field>, 
        _abstractFields:Array<Field>) 
    {   
        // preprocess the arguments
        var argExprs = [];
        var conCallArgs = [];
        for (a in _bind.arguments) {
            var argName = '${a.name}';
            argExprs.push({name:argName, type:TPath(a.type)});            
            if (TypeMacros.isTypeNative(a.type.name))
                conCallArgs.push('untyped __cpp__("(const GDNativeTypePtr)&${argName}")');
            else
                conCallArgs.push('untyped __cpp__("(const GDNativeTypePtr){0}", ${argName}.native_ptr())');
        }
        var vArgs = _assembleCallArgs(conCallArgs);

        // add static factory function to class
        var exprs = [];
        if (conCallArgs.length > 0) {
            exprs.push(macro {
                ${vArgs};
                untyped __cpp__('((GDNativePtrConstructor){0})({1}, (const GDNativeTypePtr*)call_args.data());', 
                    $i{"_"+_bind.name},
                    inst.native_ptr()
                );
            });
        } else {
            exprs.push(macro {
                untyped __cpp__('((GDNativePtrConstructor){0})({1}, nullptr);', 
                    $i{"_"+_bind.name},
                    inst.native_ptr()
                );
            });
        }

        // add static factory function to class
        var tpath = _bind.clazz.typePath;
        _fields.push({
            name: _bind.name,
            access: _bind.access,
            meta: [{name: ':noCompletion', pos: Context.currentPos()}],
            pos: Context.currentPos(),
            kind: FFun({
                args: argExprs,
                expr: macro {
                    var inst = new $tpath();
                    cpp.vm.Gc.setFinalizer(inst, cpp.Callable.fromStaticFunction(_destruct));

                    $b{exprs};

                    return inst;
                },
                params: [],
                ret: TPath(_bind.returnType)
            })
        });

        // forward constructor to abstracts
        if (_index == 0) { // create the plain new constructor
            _abstractFields.push({
                name: "new",
                access: [AInline, APublic],
                pos: Context.currentPos(),
                kind: FFun({
                    args: [],
                    expr: Context.parse('{ this = ${_bind.clazz.name}.${_bind.name}(); }', Context.currentPos()),
                    params: [],
                    ret: TPath(_bind.returnType)
                })
            });
        } else { // create a custom constructor with proper argument forwarding
            var conName = _bind.name;
            var conCallArgs = [];
            
            if (_bind.arguments.length > 0) {
                // apply some basic naming scheme that takes the argument names/types into account
                if (_bind.arguments.length == 1) {
                    conName = "from" + _bind.arguments[0].type.name;
                    conCallArgs.push(_bind.arguments[0].name);
                } else {
                    var tokens = ["from"];
                    for (a in _bind.arguments) {
                        var n = a.name.split("_");
                        tokens.push(n[0].substr(0, 1).toUpperCase() + n[0].substr(1));
                        conCallArgs.push(a.name);
                    }
                    conName = tokens.join("");
                }
            }

            _abstractFields.push({
                name: conName,
                access: [AInline, APublic, AStatic],
                pos: Context.currentPos(),
                kind: FFun({
                    args: argExprs,
                    expr: Context.parse('{ return ${_bind.clazz.name}.${_bind.name}(${conCallArgs.join(",")}); }', Context.currentPos()),
                    params: [],
                    ret: TPath(_bind.returnType)
                })
            });
        }
    }

    // 
    public static function buildDestructor(_bind:FunctionBind, _fields:Array<Field>) {
        _fields.push({
            name: '_destruct',
            access: [APrivate, AStatic],
            pos: Context.currentPos(),
            meta: [{name: ':noCompletion', pos: Context.currentPos()}],
            kind: FFun({
                args: [{name: '_this', type: TPath(_bind.clazz.typePath)}],
                expr: macro { 
                    untyped __cpp__('((GDNativePtrDestructor){0})(&({1}->opaque))', _destructor, _this);
                },
                params: [],
                ret: TPath(_bind.returnType)
            })
        });
    }

    // 
    public static function buildMethod(_bind:FunctionBind, _fields:Array<Field>) {
        var mname = '_method_${_bind.name}';

        // preprocess the arguments
        var argExprs = [];
        var conCallArgs = [];
        for (a in _bind.arguments) {
            var argName = '${a.name}';
            argExprs.push({name:argName, type:TPath(a.type)});            
            if (TypeMacros.isTypeNative(a.type.name))
                conCallArgs.push('untyped __cpp__("(const GDNativeTypePtr)&${argName}")');
            else
                conCallArgs.push('untyped __cpp__("(const GDNativeTypePtr){0}", ${argName}.native_ptr())');
        }
        var vArgs = _assembleCallArgs(conCallArgs);

        // now build the function body
        var body = null;
        if (_bind.returnType.name == "Void") {
            var exprs = [];
            if (conCallArgs.length > 0) {
                exprs.push(macro {
                    ${vArgs};
                    untyped __cpp__('((GDNativePtrBuiltInMethod){0})({1}, (const GDNativeTypePtr*)call_args.data(), nullptr, {3});', 
                        $i{mname},
                        this.native_ptr(),
                        ret,
                        $v{conCallArgs.length}
                    );
                });
            } else {
                exprs.push(macro {
                    untyped __cpp__('((GDNativePtrBuiltInMethod){0})({1}, nullptr, nullptr, 0);', 
                        $i{mname},
                        this.native_ptr()
                    );
                });
            }
            body = macro {
                $b{exprs};
            };
        } else {            
            var typePath = TPath(_bind.returnType);
            var defaultValue = TypeMacros.getNativeTypeDefaultValue(_bind.returnType.name);
            var exprs = [];
            if (conCallArgs.length > 0) {
                exprs.push(macro {
                    ${vArgs};
                    untyped __cpp__('((GDNativePtrBuiltInMethod){0})({1}, (const GDNativeTypePtr*)call_args.data(), (GDNativeTypePtr)&{2}, {3});', 
                        $i{mname},
                        this.native_ptr(),
                        ret,
                        $v{conCallArgs.length}
                    );
                });
            } else {
                exprs.push(macro {
                    untyped __cpp__('((GDNativePtrBuiltInMethod){0})({1}, nullptr, (GDNativeTypePtr)&{2}, 0);', 
                        $i{mname},
                        this.native_ptr(),
                        ret
                    );
                });
            }

            if (TypeMacros.isTypeNative(_bind.returnType.name)) {
                // a native return type
                body = macro {
                    var ret:$typePath = $v{defaultValue};
                    $b{exprs};
                    return ret;
                };
            } else {
                // // we have a managed return type, create it properly
                var typePath = _bind.returnType;
                body = macro {
                    var ret = new $typePath();
                    $b{exprs};
                    return ret;
                };
            }
        }
        _fields.push({
            name: _bind.name,
            access: _bind.access,
            pos: Context.currentPos(),
            kind: FFun({
                args: argExprs,
                expr: body,
                params: [],
                ret: TPath(_bind.returnType)
            })
        });
    }

    // utils
    static function _assembleCallArgs(_conCallArgs:Array<String>) {
        // wtf is even happening? Well, we assemble a std::array in using several untyped __cpp__ calls to allow for proper typing...
        var tmp = [for (i in 0..._conCallArgs.length) '{$i}'];
        var sArgs = 'std::array<const GDNativeTypePtr, ${_conCallArgs.length}> call_args = { ${tmp.join(",")} }';
        var tmp2 = 'untyped __cpp__("$sArgs", ${_conCallArgs.length > 0 ? _conCallArgs.join(",") : null})';
        return Context.parse(tmp2, Context.currentPos());
    }
}