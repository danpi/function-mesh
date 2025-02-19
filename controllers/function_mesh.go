// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package controllers

import (
	"context"

	"github.com/streamnative/function-mesh/api/v1alpha1"
	"github.com/streamnative/function-mesh/controllers/spec"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
)

func (r *FunctionMeshReconciler) ObserveFunctionMesh(ctx context.Context, req ctrl.Request,
	mesh *v1alpha1.FunctionMesh) error {
	// TODO update deleted function status
	if err := r.observeFunctions(ctx, mesh); err != nil {
		return err
	}

	if err := r.observeSources(ctx, mesh); err != nil {
		return err
	}

	if err := r.observeSinks(ctx, mesh); err != nil {
		return err
	}

	return nil
}

func (r *FunctionMeshReconciler) observeFunctions(ctx context.Context, mesh *v1alpha1.FunctionMesh) error {
	orphanedFunctions := map[string]bool{}

	if len(mesh.Status.FunctionConditions) > 0 {
		for functionName := range mesh.Status.FunctionConditions {
			orphanedFunctions[functionName] = true
		}
	}

	for _, functionSpec := range mesh.Spec.Functions {
		delete(orphanedFunctions, functionSpec.Name)

		// present the original name to use in Status, but underlying use the complete-name
		condition, ok := mesh.Status.FunctionConditions[functionSpec.Name]
		if !ok {
			mesh.Status.FunctionConditions[functionSpec.Name] = v1alpha1.ResourceCondition{
				Condition: v1alpha1.FunctionReady,
				Status:    metav1.ConditionFalse,
				Action:    v1alpha1.Create,
			}
			continue
		}

		function := &v1alpha1.Function{}
		err := r.Get(ctx, types.NamespacedName{
			Namespace: mesh.Namespace,
			Name:      makeComponentName(mesh.Name, functionSpec.Name),
		}, function)
		if err != nil {
			if errors.IsNotFound(err) {
				r.Log.Info("function is not ready", "name", functionSpec.Name)
				continue
			}
			return err
		}

		if function.Status.Conditions[v1alpha1.StatefulSet].Status == metav1.ConditionTrue &&
			function.Status.Conditions[v1alpha1.Service].Status == metav1.ConditionTrue {
			condition.Action = v1alpha1.NoAction
			condition.Status = metav1.ConditionTrue
			mesh.Status.FunctionConditions[functionSpec.Name] = condition
		} else {
			// function created but subcomponents not ready, we need to wait
			condition.Action = v1alpha1.Wait
			mesh.Status.FunctionConditions[functionSpec.Name] = condition
		}
	}

	for functionName, isOrphaned := range orphanedFunctions {
		if isOrphaned {
			mesh.Status.FunctionConditions[functionName] = v1alpha1.CreateCondition(
				v1alpha1.Orphaned,
				metav1.ConditionTrue,
				v1alpha1.Delete)
		}
	}

	return nil
}

func (r *FunctionMeshReconciler) observeSources(ctx context.Context, mesh *v1alpha1.FunctionMesh) error {
	orphanedSources := map[string]bool{}

	if len(mesh.Status.SourceConditions) > 0 {
		for sourceName := range mesh.Status.SourceConditions {
			orphanedSources[sourceName] = true
		}
	}

	for _, sourceSpec := range mesh.Spec.Sources {
		delete(orphanedSources, sourceSpec.Name)

		// present the original name to use in Status, but underlying use the complete-name
		condition, ok := mesh.Status.SourceConditions[sourceSpec.Name]
		if !ok {
			mesh.Status.SourceConditions[sourceSpec.Name] = v1alpha1.ResourceCondition{
				Condition: v1alpha1.SourceReady,
				Status:    metav1.ConditionFalse,
				Action:    v1alpha1.Create,
			}
			continue
		}

		source := &v1alpha1.Source{}
		err := r.Get(ctx, types.NamespacedName{
			Namespace: mesh.Namespace,
			Name:      makeComponentName(mesh.Name, sourceSpec.Name),
		}, source)
		if err != nil {
			if errors.IsNotFound(err) {
				r.Log.Info("source is not ready", "name", sourceSpec.Name)
				continue
			}
			return err
		}

		if source.Status.Conditions[v1alpha1.StatefulSet].Status == metav1.ConditionTrue &&
			source.Status.Conditions[v1alpha1.Service].Status == metav1.ConditionTrue {
			condition.Action = v1alpha1.NoAction
			condition.Status = metav1.ConditionTrue
			mesh.Status.SourceConditions[sourceSpec.Name] = condition
		} else {
			// function created but subcomponents not ready, we need to wait
			condition.Action = v1alpha1.Wait
			mesh.Status.SourceConditions[sourceSpec.Name] = condition
		}
	}

	for sourceName, isOrphaned := range orphanedSources {
		if isOrphaned {
			mesh.Status.SourceConditions[sourceName] = v1alpha1.CreateCondition(
				v1alpha1.Orphaned,
				metav1.ConditionTrue,
				v1alpha1.Delete)
		}
	}
	return nil
}

func (r *FunctionMeshReconciler) observeSinks(ctx context.Context, mesh *v1alpha1.FunctionMesh) error {
	orphanedSinks := map[string]bool{}

	if len(mesh.Status.SinkConditions) > 0 {
		for sinkName := range mesh.Status.SinkConditions {
			orphanedSinks[sinkName] = true
		}
	}

	for _, sinkSpec := range mesh.Spec.Sinks {
		delete(orphanedSinks, sinkSpec.Name)

		// present the original name to use in Status, but underlying use the complete-name
		condition, ok := mesh.Status.SinkConditions[sinkSpec.Name]
		if !ok {
			mesh.Status.SinkConditions[sinkSpec.Name] = v1alpha1.ResourceCondition{
				Condition: v1alpha1.SinkReady,
				Status:    metav1.ConditionFalse,
				Action:    v1alpha1.Create,
			}
			continue
		}

		sink := &v1alpha1.Sink{}
		err := r.Get(ctx, types.NamespacedName{
			Namespace: mesh.Namespace,
			Name:      makeComponentName(mesh.Name, sinkSpec.Name),
		}, sink)
		if err != nil {
			if errors.IsNotFound(err) {
				r.Log.Info("sink is not ready", "name", sinkSpec.Name)
				continue
			}
			return err
		}

		if sink.Status.Conditions[v1alpha1.StatefulSet].Status == metav1.ConditionTrue &&
			sink.Status.Conditions[v1alpha1.Service].Status == metav1.ConditionTrue {
			condition.Action = v1alpha1.NoAction
			condition.Status = metav1.ConditionTrue
			mesh.Status.SinkConditions[sinkSpec.Name] = condition
		} else {
			// function created but subcomponents not ready, we need to wait
			condition.Action = v1alpha1.Wait
			mesh.Status.SinkConditions[sinkSpec.Name] = condition
		}
	}

	for sinkName, isOrphaned := range orphanedSinks {
		if isOrphaned {
			mesh.Status.SinkConditions[sinkName] = v1alpha1.CreateCondition(
				v1alpha1.Orphaned,
				metav1.ConditionTrue,
				v1alpha1.Delete)
		}
	}

	return nil
}

func (r *FunctionMeshReconciler) UpdateFunctionMesh(ctx context.Context, req ctrl.Request,
	mesh *v1alpha1.FunctionMesh) error {
	defer func() {
		err := r.Status().Update(ctx, mesh)
		if err != nil {
			r.Log.Error(err, "failed to update mesh status")
		}
	}()

	for _, functionSpec := range mesh.Spec.Functions {
		condition := mesh.Status.FunctionConditions[functionSpec.Name]
		function := spec.MakeFunctionComponent(makeComponentName(mesh.Name, functionSpec.Name), mesh, &functionSpec)
		if err := r.CreateOrUpdateFunction(ctx, function, function.Spec); err != nil {
			r.Log.Error(err, "failed to handle function", "name", functionSpec.Name, "action", condition.Action)
			return err
		}
	}

	for _, sourceSpec := range mesh.Spec.Sources {
		condition := mesh.Status.SourceConditions[sourceSpec.Name]
		source := spec.MakeSourceComponent(makeComponentName(mesh.Name, sourceSpec.Name), mesh, &sourceSpec)
		if err := r.CreateOrUpdateSource(ctx, source, source.Spec); err != nil {
			r.Log.Error(err, "failed to handle soure", "name", sourceSpec.Name, "action", condition.Action)
			return err
		}
	}

	for _, sinkSpec := range mesh.Spec.Sinks {
		condition := mesh.Status.SinkConditions[sinkSpec.Name]
		sink := spec.MakeSinkComponent(makeComponentName(mesh.Name, sinkSpec.Name), mesh, &sinkSpec)
		if err := r.CreateOrUpdateSink(ctx, sink, sink.Spec); err != nil {
			r.Log.Error(err, "failed to handle sink", "name", sinkSpec.Name, "action", condition.Action)
			return err
		}
	}

	// handle logic for cleaning up orphaned subcomponents
	if len(mesh.Spec.Functions) != len(mesh.Status.FunctionConditions) {
		for functionName, functionCondition := range mesh.Status.FunctionConditions {
			if functionCondition.Condition == v1alpha1.Orphaned {
				// clean up the orphaned functions
				function := &v1alpha1.Function{}
				if err := r.Get(ctx, types.NamespacedName{
					Namespace: mesh.Namespace,
					Name:      makeComponentName(mesh.Name, functionName),
				}, function); err != nil {
					if errors.IsNotFound(err) {
						delete(mesh.Status.FunctionConditions, functionName)
						continue
					}
					r.Log.Error(err, "failed to get orphaned function", "name", functionName)
					return err
				}
				if err := r.Delete(ctx, function); err != nil && !errors.IsNotFound(err) {
					r.Log.Error(err, "failed to delete orphaned function", "name", functionName)
					return err
				}
				delete(mesh.Status.FunctionConditions, functionName)
			}
		}
	}

	if len(mesh.Spec.Sources) != len(mesh.Status.SourceConditions) {
		for sourceName, sourceCondition := range mesh.Status.SourceConditions {
			if sourceCondition.Condition == v1alpha1.Orphaned {
				// clean up the orphaned sources
				source := &v1alpha1.Source{}
				if err := r.Get(ctx, types.NamespacedName{
					Namespace: mesh.Namespace,
					Name:      makeComponentName(mesh.Name, sourceName),
				}, source); err != nil {
					if errors.IsNotFound(err) {
						delete(mesh.Status.SourceConditions, sourceName)
						continue
					}
					r.Log.Error(err, "failed to get orphaned source", "name", sourceName)
					return err
				}
				if err := r.Delete(ctx, source); err != nil && !errors.IsNotFound(err) {
					r.Log.Error(err, "failed to delete orphaned source", "name", sourceName)
					return err
				}
				delete(mesh.Status.SourceConditions, sourceName)
			}
		}
	}

	if len(mesh.Spec.Sinks) != len(mesh.Status.SinkConditions) {
		for sinkName, sinkCondition := range mesh.Status.SinkConditions {
			if sinkCondition.Condition == v1alpha1.Orphaned {
				// clean up the orphaned sinks
				sink := &v1alpha1.Sink{}
				if err := r.Get(ctx, types.NamespacedName{
					Namespace: mesh.Namespace,
					Name:      makeComponentName(mesh.Name, sinkName),
				}, sink); err != nil {
					if errors.IsNotFound(err) {
						delete(mesh.Status.SinkConditions, sinkName)
						continue
					}
					r.Log.Error(err, "failed to get orphaned sink", "name", sinkName)
					return err
				}
				if err := r.Delete(ctx, sink); err != nil && !errors.IsNotFound(err) {
					r.Log.Error(err, "failed to delete orphaned sink", "name", sinkName)
					return err
				}
				delete(mesh.Status.SinkConditions, sinkName)
			}
		}
	}

	return nil
}

func (r *FunctionMeshReconciler) CreateOrUpdateFunction(ctx context.Context, function *v1alpha1.Function, functionSpec v1alpha1.FunctionSpec) error {
	if _, err := ctrl.CreateOrUpdate(ctx, r.Client, function, func() error {
		// function mutate logic
		function.Spec = functionSpec
		return nil
	}); err != nil {
		r.Log.Error(err, "error create or update function", "namespace", function.Namespace, "name", function.Name)
		return err
	}
	return nil
}

func (r *FunctionMeshReconciler) CreateOrUpdateSink(ctx context.Context, sink *v1alpha1.Sink, sinkSpec v1alpha1.SinkSpec) error {
	if _, err := ctrl.CreateOrUpdate(ctx, r.Client, sink, func() error {
		// sink mutate logic
		sink.Spec = sinkSpec
		return nil
	}); err != nil {
		r.Log.Error(err, "error create or update sink", "namespace", sink.Namespace, "name", sink.Name)
		return err
	}
	return nil
}

func (r *FunctionMeshReconciler) CreateOrUpdateSource(ctx context.Context, source *v1alpha1.Source, sourceSpec v1alpha1.SourceSpec) error {
	if _, err := ctrl.CreateOrUpdate(ctx, r.Client, source, func() error {
		// source mutate logic
		source.Spec = sourceSpec
		return nil
	}); err != nil {
		r.Log.Error(err, "error create or update source", "namespace", source.Namespace, "name", source.Name)
		return err
	}
	return nil
}

func makeComponentName(prefix, name string) string {
	return prefix + "-" + name
}
