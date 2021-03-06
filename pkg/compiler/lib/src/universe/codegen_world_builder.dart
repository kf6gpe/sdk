// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import '../common/names.dart' show Identifiers;
import '../common_elements.dart';
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/types.dart';
import '../js_backend/native_data.dart' show NativeBasicData;
import '../js_model/locals.dart';
import '../js_model/element_map_impl.dart';
import '../util/enumset.dart';
import '../util/util.dart';
import '../world.dart' show JClosedWorld;
import 'member_usage.dart';
import 'selector.dart' show Selector;
import 'use.dart'
    show
        ConstantUse,
        ConstantUseKind,
        DynamicUse,
        DynamicUseKind,
        StaticUse,
        StaticUseKind;
import 'world_builder.dart';

/// World builder specific to codegen.
///
/// This adds additional access to liveness of selectors and elements.
abstract class CodegenWorldBuilder implements WorldBuilder {
  /// All directly or indirectly instantiated classes.
  Iterable<ClassEntity> get instantiatedClasses;

  /// Calls [f] with every instance field, together with its declarer, in an
  /// instance of [cls]. All fields inherited from superclasses and mixins are
  /// included.
  ///
  /// If [isElided] is `true`, the field is not read and should therefore not
  /// be emitted.
  void forEachInstanceField(covariant ClassEntity cls,
      void f(ClassEntity declarer, FieldEntity field, {bool isElided}));

  /// Calls [f] with every instance field declared directly in class [cls]
  /// (i.e. no inherited fields). Fields are presented in initialization
  /// (i.e. textual) order.
  ///
  /// If [isElided] is `true`, the field is not read and should therefore not
  /// be emitted.
  void forEachDirectInstanceField(
      covariant ClassEntity cls, void f(FieldEntity field, {bool isElided}));

  /// Calls [f] for each parameter of [function] providing the type and name of
  /// the parameter and the [defaultValue] if the parameter is optional.
  void forEachParameter(covariant FunctionEntity function,
      void f(DartType type, String name, ConstantValue defaultValue));

  /// Calls [f] for each parameter - given as a [Local] - of [function].
  void forEachParameterAsLocal(
      covariant FunctionEntity function, void f(Local parameter));

  void forEachInvokedName(
      f(String name, Map<Selector, SelectorConstraints> selectors));

  void forEachInvokedGetter(
      f(String name, Map<Selector, SelectorConstraints> selectors));

  void forEachInvokedSetter(
      f(String name, Map<Selector, SelectorConstraints> selectors));

  /// Returns `true` if [member] is invoked as a setter.
  bool hasInvokedSetter(MemberEntity member);

  bool hasInvokedGetter(MemberEntity member);

  Map<Selector, SelectorConstraints> invocationsByName(String name);

  Map<Selector, SelectorConstraints> getterInvocationsByName(String name);

  Map<Selector, SelectorConstraints> setterInvocationsByName(String name);

  Iterable<FunctionEntity> get staticFunctionsNeedingGetter;
  Iterable<FunctionEntity> get methodsNeedingSuperGetter;

  /// The set of all referenced static fields.
  ///
  /// Invariant: Elements are declaration elements.
  Iterable<FieldEntity> get allReferencedStaticFields;

  /// Set of methods in instantiated classes that are potentially closurized.
  Iterable<FunctionEntity> get closurizedMembers;

  /// Register [constant] as needed for emission.
  void addCompileTimeConstantForEmission(ConstantValue constant);

  /// Returns a list of constants topologically sorted so that dependencies
  /// appear before the dependent constant.
  ///
  /// [preSortCompare] is a comparator function that gives the constants a
  /// consistent order prior to the topological sort which gives the constants
  /// an ordering that is less sensitive to perturbations in the source code.
  List<ConstantValue> getConstantsForEmission(
      [Comparator<ConstantValue> preSortCompare]);

  /// Returns the types that are live as constant type literals.
  Iterable<DartType> get constTypeLiterals;

  /// Returns the types that are live as constant type arguments.
  Iterable<DartType> get liveTypeArguments;
}

class CodegenWorldBuilderImpl extends WorldBuilderBase
    implements CodegenWorldBuilder {
  final JClosedWorld _world;

  /// The set of all directly instantiated classes, that is, classes with a
  /// generative constructor that has been called directly and not only through
  /// a super-call.
  ///
  /// Invariant: Elements are declaration elements.
  // TODO(johnniwinther): [_directlyInstantiatedClasses] and
  // [_instantiatedTypes] sets should be merged.
  final Set<ClassEntity> _directlyInstantiatedClasses = new Set<ClassEntity>();

  /// The set of all directly instantiated types, that is, the types of the
  /// directly instantiated classes.
  ///
  /// See [_directlyInstantiatedClasses].
  final Set<InterfaceType> _instantiatedTypes = new Set<InterfaceType>();

  /// Classes implemented by directly instantiated classes.
  final Set<ClassEntity> _implementedClasses = new Set<ClassEntity>();

  /// The set of all referenced static fields.
  ///
  /// Invariant: Elements are declaration elements.
  final Set<FieldEntity> allReferencedStaticFields = new Set<FieldEntity>();

  /// Documentation wanted -- johnniwinther
  ///
  /// Invariant: Elements are declaration elements.
  final Set<FunctionEntity> staticFunctionsNeedingGetter =
      new Set<FunctionEntity>();
  final Set<FunctionEntity> methodsNeedingSuperGetter =
      new Set<FunctionEntity>();
  final Map<String, Map<Selector, SelectorConstraints>> _invokedNames =
      <String, Map<Selector, SelectorConstraints>>{};
  final Map<String, Map<Selector, SelectorConstraints>> _invokedGetters =
      <String, Map<Selector, SelectorConstraints>>{};
  final Map<String, Map<Selector, SelectorConstraints>> _invokedSetters =
      <String, Map<Selector, SelectorConstraints>>{};

  final Map<ClassEntity, ClassUsage> _processedClasses =
      <ClassEntity, ClassUsage>{};

  Map<ClassEntity, ClassUsage> get classUsageForTesting => _processedClasses;

  /// Map of registered usage of static members of live classes.
  final Map<Entity, StaticMemberUsage> _staticMemberUsage =
      <Entity, StaticMemberUsage>{};

  Map<Entity, StaticMemberUsage> get staticMemberUsageForTesting =>
      _staticMemberUsage;

  /// Map of registered usage of instance members of live classes.
  final Map<MemberEntity, MemberUsage> _instanceMemberUsage =
      <MemberEntity, MemberUsage>{};

  Map<MemberEntity, MemberUsage> get instanceMemberUsageForTesting =>
      _instanceMemberUsage;

  /// Map containing instance members of live classes that are not yet live
  /// themselves.
  final Map<String, Set<MemberUsage>> _instanceMembersByName =
      <String, Set<MemberUsage>>{};

  /// Map containing instance methods of live classes that are not yet
  /// closurized.
  final Map<String, Set<MemberUsage>> _instanceFunctionsByName =
      <String, Set<MemberUsage>>{};

  final Set<DartType> isChecks = new Set<DartType>();

  final SelectorConstraintsStrategy selectorConstraintsStrategy;

  final Set<ConstantValue> _constantValues = new Set<ConstantValue>();

  final JsToWorldBuilder _elementMap;

  final Set<DartType> _constTypeLiterals = new Set<DartType>();
  final Set<DartType> _liveTypeArguments = new Set<DartType>();

  CodegenWorldBuilderImpl(
      this._elementMap, this._world, this.selectorConstraintsStrategy);

  ElementEnvironment get _elementEnvironment => _world.elementEnvironment;

  NativeBasicData get _nativeBasicData => _world.nativeData;

  GlobalLocalsMap get _globalLocalsMap => _world.globalLocalsMap;

  Iterable<ClassEntity> get instantiatedClasses => _processedClasses.keys
      .where((cls) => _processedClasses[cls].isInstantiated);

  /// All directly instantiated classes, that is, classes with a generative
  /// constructor that has been called directly and not only through a
  /// super-call.
  // TODO(johnniwinther): Improve semantic precision.
  Iterable<ClassEntity> get directlyInstantiatedClasses {
    return _directlyInstantiatedClasses;
  }

  /// All directly instantiated types, that is, the types of the directly
  /// instantiated classes.
  ///
  /// See [directlyInstantiatedClasses].
  // TODO(johnniwinther): Improve semantic precision.
  Iterable<InterfaceType> get instantiatedTypes => _instantiatedTypes;

  /// Register [type] as (directly) instantiated.
  ///
  /// If [byMirrors] is `true`, the instantiation is through mirrors.
  // TODO(johnniwinther): Fully enforce the separation between exact, through
  // subclass and through subtype instantiated types/classes.
  // TODO(johnniwinther): Support unknown type arguments for generic types.
  void registerTypeInstantiation(
      InterfaceType type, ClassUsedCallback classUsed) {
    ClassEntity cls = type.element;
    bool isNative = _nativeBasicData.isNativeClass(cls);
    _instantiatedTypes.add(type);
    // We can't use the closed-world assumption with native abstract
    // classes; a native abstract class may have non-abstract subclasses
    // not declared to the program.  Instances of these classes are
    // indistinguishable from the abstract class.
    if (!cls.isAbstract || isNative) {
      _directlyInstantiatedClasses.add(cls);
      _processInstantiatedClass(cls, classUsed);
    }

    // TODO(johnniwinther): Replace this by separate more specific mappings that
    // include the type arguments.
    if (_implementedClasses.add(cls)) {
      classUsed(cls, _getClassUsage(cls).implement());
      _elementEnvironment.forEachSupertype(cls, (InterfaceType supertype) {
        if (_implementedClasses.add(supertype.element)) {
          classUsed(
              supertype.element, _getClassUsage(supertype.element).implement());
        }
      });
    }
  }

  bool _hasMatchingSelector(Map<Selector, SelectorConstraints> selectors,
      MemberEntity member, JClosedWorld world) {
    if (selectors == null) return false;
    for (Selector selector in selectors.keys) {
      if (selector.appliesUnnamed(member)) {
        SelectorConstraints masks = selectors[selector];
        if (masks.canHit(member, selector.memberName, world)) {
          return true;
        }
      }
    }
    return false;
  }

  bool hasInvocation(MemberEntity member) {
    return _hasMatchingSelector(_invokedNames[member.name], member, _world);
  }

  bool hasInvokedGetter(MemberEntity member) {
    return _hasMatchingSelector(_invokedGetters[member.name], member, _world) ||
        member.isFunction && methodsNeedingSuperGetter.contains(member);
  }

  bool hasInvokedSetter(MemberEntity member) {
    return _hasMatchingSelector(_invokedSetters[member.name], member, _world);
  }

  bool registerDynamicUse(
      DynamicUse dynamicUse, MemberUsedCallback memberUsed) {
    Selector selector = dynamicUse.selector;
    String methodName = selector.name;

    void _process(Map<String, Set<MemberUsage>> memberMap,
        EnumSet<MemberUse> action(MemberUsage usage)) {
      _processSet(memberMap, methodName, (MemberUsage usage) {
        if (selector.appliesUnnamed(usage.entity) &&
            selectorConstraintsStrategy.appliedUnnamed(
                dynamicUse, usage.entity, _world)) {
          memberUsed(usage.entity, action(usage));
          return true;
        }
        return false;
      });
    }

    switch (dynamicUse.kind) {
      case DynamicUseKind.INVOKE:
        registerDynamicInvocation(
            dynamicUse.selector, dynamicUse.typeArguments);
        if (_registerNewSelector(dynamicUse, _invokedNames)) {
          // We don't track parameters in the codegen world builder, so we
          // pass `null` instead of the concrete call structure.
          _process(_instanceMembersByName, (m) => m.invoke(null));
          return true;
        }
        break;
      case DynamicUseKind.GET:
        if (_registerNewSelector(dynamicUse, _invokedGetters)) {
          _process(_instanceMembersByName, (m) => m.read());
          _process(_instanceFunctionsByName, (m) => m.read());
          return true;
        }
        break;
      case DynamicUseKind.SET:
        if (_registerNewSelector(dynamicUse, _invokedSetters)) {
          _process(_instanceMembersByName, (m) => m.write());
          return true;
        }
        break;
    }
    return false;
  }

  bool _registerNewSelector(DynamicUse dynamicUse,
      Map<String, Map<Selector, SelectorConstraints>> selectorMap) {
    Selector selector = dynamicUse.selector;
    String name = selector.name;
    Object constraint = dynamicUse.receiverConstraint;
    Map<Selector, SelectorConstraints> selectors =
        selectorMap[name] ??= new Maplet<Selector, SelectorConstraints>();
    UniverseSelectorConstraints constraints = selectors[selector];
    if (constraints == null) {
      selectors[selector] = selectorConstraintsStrategy
          .createSelectorConstraints(selector, constraint);
      return true;
    }
    return constraints.addReceiverConstraint(constraint);
  }

  Map<Selector, SelectorConstraints> _asUnmodifiable(
      Map<Selector, SelectorConstraints> map) {
    if (map == null) return null;
    return new UnmodifiableMapView(map);
  }

  Map<Selector, SelectorConstraints> invocationsByName(String name) {
    return _asUnmodifiable(_invokedNames[name]);
  }

  Map<Selector, SelectorConstraints> getterInvocationsByName(String name) {
    return _asUnmodifiable(_invokedGetters[name]);
  }

  Map<Selector, SelectorConstraints> setterInvocationsByName(String name) {
    return _asUnmodifiable(_invokedSetters[name]);
  }

  void forEachInvokedName(
      f(String name, Map<Selector, SelectorConstraints> selectors)) {
    _invokedNames.forEach(f);
  }

  void forEachInvokedGetter(
      f(String name, Map<Selector, SelectorConstraints> selectors)) {
    _invokedGetters.forEach(f);
  }

  void forEachInvokedSetter(
      f(String name, Map<Selector, SelectorConstraints> selectors)) {
    _invokedSetters.forEach(f);
  }

  void registerIsCheck(covariant DartType type) {
    isChecks.add(type.unaliased);
  }

  void _registerStaticUse(StaticUse staticUse) {
    if (staticUse.element is FieldEntity) {
      FieldEntity field = staticUse.element;
      if (field.isTopLevel || field.isStatic) {
        allReferencedStaticFields.add(field);
      }
    }
    switch (staticUse.kind) {
      case StaticUseKind.STATIC_TEAR_OFF:
        staticFunctionsNeedingGetter.add(staticUse.element);
        break;
      case StaticUseKind.SUPER_TEAR_OFF:
        methodsNeedingSuperGetter.add(staticUse.element);
        break;
      case StaticUseKind.SUPER_FIELD_SET:
      case StaticUseKind.FIELD_SET:
      case StaticUseKind.CLOSURE:
      case StaticUseKind.CLOSURE_CALL:
      case StaticUseKind.CALL_METHOD:
      case StaticUseKind.FIELD_GET:
      case StaticUseKind.CONSTRUCTOR_INVOKE:
      case StaticUseKind.CONST_CONSTRUCTOR_INVOKE:
      case StaticUseKind.REDIRECTION:
      case StaticUseKind.DIRECT_INVOKE:
      case StaticUseKind.INLINING:
      case StaticUseKind.INVOKE:
      case StaticUseKind.GET:
      case StaticUseKind.SET:
      case StaticUseKind.INIT:
        break;
    }
  }

  void registerStaticUse(StaticUse staticUse, MemberUsedCallback memberUsed) {
    Entity element = staticUse.element;
    _registerStaticUse(staticUse);
    StaticMemberUsage usage = _staticMemberUsage.putIfAbsent(element, () {
      if (element is MemberEntity &&
          (element.isStatic || element.isTopLevel) &&
          element.isFunction) {
        return new StaticFunctionUsage(element);
      } else {
        return new GeneralStaticMemberUsage(element);
      }
    });
    EnumSet<MemberUse> useSet = new EnumSet<MemberUse>();
    switch (staticUse.kind) {
      case StaticUseKind.STATIC_TEAR_OFF:
        closurizedStatics.add(element);
        useSet.addAll(usage.tearOff());
        break;
      case StaticUseKind.FIELD_GET:
      case StaticUseKind.FIELD_SET:
      case StaticUseKind.CLOSURE:
      case StaticUseKind.CLOSURE_CALL:
      case StaticUseKind.CALL_METHOD:
        // TODO(johnniwinther): Avoid this. Currently [FIELD_GET] and
        // [FIELD_SET] contains [BoxFieldElement]s which we cannot enqueue.
        // Also [CLOSURE] contains [LocalFunctionElement] which we cannot
        // enqueue.
        break;
      case StaticUseKind.INVOKE:
        registerStaticInvocation(staticUse);
        useSet.addAll(usage.normalUse());
        break;
      case StaticUseKind.SUPER_FIELD_SET:
      case StaticUseKind.SUPER_TEAR_OFF:
      case StaticUseKind.GET:
      case StaticUseKind.SET:
      case StaticUseKind.INIT:
        useSet.addAll(usage.normalUse());
        break;
      case StaticUseKind.CONSTRUCTOR_INVOKE:
      case StaticUseKind.CONST_CONSTRUCTOR_INVOKE:
      case StaticUseKind.REDIRECTION:
        useSet.addAll(usage.normalUse());
        break;
      case StaticUseKind.DIRECT_INVOKE:
        MemberEntity member = staticUse.element;
        MemberUsage instanceUsage = _getMemberUsage(member, memberUsed);
        // We don't track parameters in the codegen world builder, so we
        // pass `null` instead of the concrete call structure.
        memberUsed(instanceUsage.entity, instanceUsage.invoke(null));
        _instanceMembersByName[instanceUsage.entity.name]
            ?.remove(instanceUsage);
        useSet.addAll(usage.normalUse());
        if (staticUse.typeArguments?.isNotEmpty ?? false) {
          registerDynamicInvocation(
              new Selector.call(member.memberName, staticUse.callStructure),
              staticUse.typeArguments);
        }
        break;
      case StaticUseKind.INLINING:
        registerStaticInvocation(staticUse);
        break;
    }
    if (useSet.isNotEmpty) {
      memberUsed(usage.entity, useSet);
    }
  }

  /// Registers that [element] has been closurized.
  void registerClosurizedMember(MemberEntity element) {
    closurizedMembers.add(element);
  }

  void processClassMembers(ClassEntity cls, MemberUsedCallback memberUsed) {
    _elementEnvironment.forEachClassMember(cls,
        (ClassEntity cls, MemberEntity member) {
      _processInstantiatedClassMember(cls, member, memberUsed);
    });
  }

  void _processInstantiatedClassMember(ClassEntity cls,
      covariant MemberEntity member, MemberUsedCallback memberUsed) {
    if (!member.isInstanceMember) return;
    _getMemberUsage(member, memberUsed);
  }

  MemberUsage _getMemberUsage(
      covariant MemberEntity member, MemberUsedCallback memberUsed) {
    // TODO(johnniwinther): Change [TypeMask] to not apply to a superclass
    // member unless the class has been instantiated. Similar to
    // [StrongModeConstraint].
    return _instanceMemberUsage.putIfAbsent(member, () {
      String memberName = member.name;
      ClassEntity cls = member.enclosingClass;
      bool isNative = _nativeBasicData.isNativeClass(cls);
      MemberUsage usage = new MemberUsage(member, isNative: isNative);
      EnumSet<MemberUse> useSet = new EnumSet<MemberUse>();
      useSet.addAll(usage.appliedUse);
      if (!usage.hasRead && hasInvokedGetter(member)) {
        useSet.addAll(usage.read());
      }
      if (!usage.hasWrite && hasInvokedSetter(member)) {
        useSet.addAll(usage.write());
      }
      if (!usage.hasInvoke && hasInvocation(member)) {
        // We don't track parameters in the codegen world builder, so we
        // pass `null` instead of the concrete call structures.
        useSet.addAll(usage.invoke(null));
      }

      if (usage.hasPendingClosurizationUse) {
        // Store the member in [instanceFunctionsByName] to catch
        // getters on the function.
        _instanceFunctionsByName
            .putIfAbsent(usage.entity.name, () => new Set<MemberUsage>())
            .add(usage);
      }
      if (usage.hasPendingNormalUse) {
        // The element is not yet used. Add it to the list of instance
        // members to still be processed.
        _instanceMembersByName
            .putIfAbsent(memberName, () => new Set<MemberUsage>())
            .add(usage);
      }
      memberUsed(member, useSet);
      return usage;
    });
  }

  void _processSet(Map<String, Set<MemberUsage>> map, String memberName,
      bool f(MemberUsage e)) {
    Set<MemberUsage> members = map[memberName];
    if (members == null) return;
    // [f] might add elements to [: map[memberName] :] during the loop below
    // so we create a new list for [: map[memberName] :] and prepend the
    // [remaining] members after the loop.
    map[memberName] = new Set<MemberUsage>();
    Set<MemberUsage> remaining = new Set<MemberUsage>();
    for (MemberUsage member in members) {
      if (!f(member)) remaining.add(member);
    }
    map[memberName].addAll(remaining);
  }

  /// Return the canonical [ClassUsage] for [cls].
  ClassUsage _getClassUsage(ClassEntity cls) {
    return _processedClasses.putIfAbsent(cls, () => new ClassUsage(cls));
  }

  void _processInstantiatedClass(ClassEntity cls, ClassUsedCallback classUsed) {
    // Registers [superclass] as instantiated. Returns `true` if it wasn't
    // already instantiated and we therefore have to process its superclass as
    // well.
    bool processClass(ClassEntity superclass) {
      ClassUsage usage = _getClassUsage(superclass);
      if (!usage.isInstantiated) {
        classUsed(usage.cls, usage.instantiate());
        return true;
      }
      return false;
    }

    while (cls != null && processClass(cls)) {
      cls = _elementEnvironment.getSuperClass(cls);
    }
  }

  /// Set of all registered compiled constants.
  final Set<ConstantValue> compiledConstants = new Set<ConstantValue>();

  @override
  void addCompileTimeConstantForEmission(ConstantValue constant) {
    compiledConstants.add(constant);
  }

  @override
  List<ConstantValue> getConstantsForEmission(
      [Comparator<ConstantValue> preSortCompare]) {
    // We must emit dependencies before their uses.
    Set<ConstantValue> seenConstants = new Set<ConstantValue>();
    List<ConstantValue> result = new List<ConstantValue>();

    void addConstant(ConstantValue constant) {
      if (!seenConstants.contains(constant)) {
        constant.getDependencies().forEach(addConstant);
        assert(!seenConstants.contains(constant));
        result.add(constant);
        seenConstants.add(constant);
      }
    }

    List<ConstantValue> sorted = compiledConstants.toList();
    if (preSortCompare != null) {
      sorted.sort(preSortCompare);
    }
    sorted.forEach(addConstant);
    return result;
  }

  /// Register the constant [use] with this world builder. Returns `true` if
  /// the constant use was new to the world.
  bool registerConstantUse(ConstantUse use) {
    if (use.kind == ConstantUseKind.DIRECT) {
      addCompileTimeConstantForEmission(use.value);
    }
    return _constantValues.add(use.value);
  }

  @override
  Iterable<Local> get genericLocalFunctions => const <Local>[];

  @override
  Iterable<FunctionEntity> get genericInstanceMethods {
    List<FunctionEntity> functions = <FunctionEntity>[];

    void processMemberUse(MemberEntity member, MemberUsage memberUsage) {
      if (member.isInstanceMember &&
          member is FunctionEntity &&
          memberUsage.hasUse &&
          _elementEnvironment.getFunctionTypeVariables(member).isNotEmpty) {
        functions.add(member);
      }
    }

    _instanceMemberUsage.forEach(processMemberUse);
    return functions;
  }

  @override
  Iterable<FunctionEntity> get userNoSuchMethods {
    List<FunctionEntity> functions = <FunctionEntity>[];

    void processMemberUse(MemberEntity member, MemberUsage memberUsage) {
      if (member.isInstanceMember &&
          member is FunctionEntity &&
          memberUsage.hasUse &&
          member.name == Identifiers.noSuchMethod_ &&
          !_world.commonElements.isDefaultNoSuchMethodImplementation(member)) {
        functions.add(member);
      }
    }

    _instanceMemberUsage.forEach(processMemberUse);
    return functions;
  }

  @override
  Iterable<FunctionEntity> get genericMethods {
    List<FunctionEntity> functions = <FunctionEntity>[];

    void processMemberUse(Entity member, AbstractUsage memberUsage) {
      if (member is FunctionEntity &&
          memberUsage.hasUse &&
          _elementEnvironment.getFunctionTypeVariables(member).isNotEmpty) {
        functions.add(member);
      }
    }

    _instanceMemberUsage.forEach(processMemberUse);
    _staticMemberUsage.forEach(processMemberUse);
    return functions;
  }

  @override
  void forEachParameter(FunctionEntity function,
      void f(DartType type, String name, ConstantValue defaultValue)) {
    _elementMap.forEachParameter(function, f,
        isNative: _world.nativeData.isNativeMember(function));
  }

  @override
  void forEachParameterAsLocal(
      FunctionEntity function, void f(Local parameter)) {
    forEachOrderedParameterAsLocal(_globalLocalsMap, _elementMap, function,
        (Local parameter, {bool isElided}) {
      if (!isElided) {
        f(parameter);
      }
    });
  }

  @override
  void forEachInstanceField(ClassEntity cls,
      void f(ClassEntity declarer, FieldEntity field, {bool isElided})) {
    _elementEnvironment.forEachClassMember(cls,
        (ClassEntity declarer, MemberEntity member) {
      if (member.isField && member.isInstanceMember) {
        f(declarer, member,
            isElided: _world.fieldAnalysis.getFieldData(member).isElided);
      }
    });
  }

  @override
  void forEachDirectInstanceField(
      ClassEntity cls, void f(FieldEntity field, {bool isElided})) {
    // TODO(sra): Add ElementEnvironment.forEachDirectInstanceField or
    // parameterize [forEachInstanceField] to filter members to avoid a
    // potentially O(n^2) scan of the superclasses.
    _elementEnvironment.forEachClassMember(cls,
        (ClassEntity declarer, MemberEntity member) {
      if (declarer != cls) return;
      if (!member.isField) return;
      if (!member.isInstanceMember) return;
      f(member, isElided: _world.fieldAnalysis.getFieldData(member).isElided);
    });
  }

  void registerConstTypeLiteral(DartType type) {
    _constTypeLiterals.add(type);
  }

  Iterable<DartType> get constTypeLiterals => _constTypeLiterals;

  void registerTypeArgument(DartType type) {
    _liveTypeArguments.add(type);
  }

  Iterable<DartType> get liveTypeArguments => _liveTypeArguments;
}
